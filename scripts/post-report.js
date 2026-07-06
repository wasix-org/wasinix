// Create the "Per-package status" check run and, on PRs, upsert the sticky
// report comment. Called via actions/github-script from ci.yml (same-repo
// events, where the job token has write perms) and from test-report.yml
// (fork PRs via workflow_run, where the in-job token is read-only). Reads
// the report files from cwd; missing files degrade to a stub so a cancelled
// run still gets a check.
const fs = require('fs');

const read = (f) => {
  try {
    return fs.readFileSync(f, 'utf8');
  } catch {
    return null;
  }
};

module.exports = async ({ github, context, core }) => {
  const isWfRun = context.eventName === 'workflow_run';
  const run = isWfRun ? context.payload.workflow_run : null;

  const headSha = isWfRun
    ? run.head_sha
    : context.eventName === 'pull_request'
      ? context.payload.pull_request.head.sha
      : context.sha;
  // Preliminary mode: called right after the eval, before the multi-hour
  // build, so the rebuild count (the build-time predictor) is on the PR
  // immediately. Creates the check run in_progress; the final call updates
  // it in place via the id file.
  const preliminary = process.env.PRELIMINARY === '1';
  const rawConclusion = isWfRun ? run.conclusion : (process.env.BUILD_OUTCOME ?? 'failure');
  const conclusion = ['success', 'failure', 'cancelled'].includes(rawConclusion)
    ? rawConclusion
    : 'neutral';

  const report = JSON.parse(read('report.json') ?? '{}');
  const diff = JSON.parse(read('diff-summary.json') ?? '{}');
  const evalTitle = diff.evalFailed
    ? 'eval failed'
    : diff.baseRev != null
      ? `building: ${diff.rebuilt} of ${diff.total} jobs rebuild`
      : 'building (no base map to diff against)';
  const title = preliminary ? evalTitle : (report.title ?? `no report produced (${rawConclusion})`);
  const body =
    [read('build-report.md'), read('content-diff.md'), read('rebuild-diff.md')]
      .filter(Boolean)
      .join('\n\n') || 'No report artifacts found.';
  // check run output.summary caps at 64k
  const summary = body.length > 60000 ? body.slice(0, 60000) + '\n\n(truncated)' : body;

  const { owner, repo } = context.repo;
  const output = { title, summary };
  const priorId = read('check-run-id');
  if (preliminary) {
    const created = await github.rest.checks.create({
      owner,
      repo,
      name: 'Per-package status',
      head_sha: headSha,
      status: 'in_progress',
      output,
    });
    fs.writeFileSync('check-run-id', String(created.data.id));
  } else if (priorId) {
    await github.rest.checks.update({
      owner,
      repo,
      check_run_id: Number(priorId),
      status: 'completed',
      conclusion,
      output,
    });
  } else {
    await github.rest.checks.create({
      owner,
      repo,
      name: 'Per-package status',
      head_sha: headSha,
      status: 'completed',
      conclusion,
      output,
    });
  }

  let issue_number;
  if (isWfRun) {
    if (run.event !== 'pull_request') return;
    // workflow_run.pull_requests is empty for fork PRs; find by head sha
    let prs = run.pull_requests;
    if (!prs.length) {
      const res = await github.rest.repos.listPullRequestsAssociatedWithCommit({
        owner,
        repo,
        commit_sha: headSha,
      });
      prs = res.data.filter((pr) => pr.state === 'open');
    }
    if (!prs.length) {
      core.warning(`no PR found for ${headSha}`);
      return;
    }
    issue_number = prs[0].number;
  } else {
    if (context.eventName !== 'pull_request') return;
    issue_number = context.payload.pull_request.number;
  }

  const marker = '<!-- wasinix-ci-report -->';
  const commentBody = marker + '\n' + summary;
  const comments = await github.paginate(github.rest.issues.listComments, {
    owner,
    repo,
    issue_number,
    per_page: 100,
  });
  const existing = comments.find((c) => c.body.startsWith(marker));
  if (existing) {
    await github.rest.issues.updateComment({
      owner,
      repo,
      comment_id: existing.id,
      body: commentBody,
    });
  } else {
    await github.rest.issues.createComment({ owner, repo, issue_number, body: commentBody });
  }
};
