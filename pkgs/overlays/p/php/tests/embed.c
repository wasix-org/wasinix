#include <sapi/embed/php_embed.h>

int main(void) {
  char *argv[] = {"php-embed-smoke", NULL};

  if (php_embed_init(1, argv) == FAILURE) {
    return 1;
  }
  if (zend_eval_string("echo 'php embed ok';", NULL, "libphp smoke") ==
      FAILURE) {
    php_embed_shutdown();
    return 1;
  }
  php_embed_shutdown();
  return 0;
}
