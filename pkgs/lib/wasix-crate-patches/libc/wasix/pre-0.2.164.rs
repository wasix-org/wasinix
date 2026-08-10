pub type sighandler_t = ::size_t;
pub type pthread_t = ::c_ulong;
pub type pthread_key_t = ::c_uint;
pub type socklen_t = u32;
pub type in_addr_t = u32;
pub type in_port_t = u16;
pub type sa_family_t = u16;
pub type sa_type_t = u16;

s! {
    #[repr(C)]
    pub struct in_addr {
        pub s_addr: ::in_addr_t,
    }

    #[repr(C)]
    #[repr(align(4))]
    pub struct in6_addr {
        pub s6_addr: [u8; 16],
    }

    #[repr(C)]
    pub struct sockaddr_un {
        pub sun_family: sa_family_t,
        pub sun_path: [::c_char; 108],
    }

    #[repr(C)]
    pub struct sockaddr {
        pub sa_family: sa_family_t,
        pub sa_data: [::c_char; 14],
    }

    #[repr(C)]
    pub struct sockaddr_in {
        pub sin_family: sa_family_t,
        pub sin_port: ::in_port_t,
        pub sin_addr: ::in_addr,
        pub sin_zero: [u8; 8],
    }

    #[repr(C)]
    pub struct sockaddr_in6 {
        pub sin6_family: sa_family_t,
        pub sin6_port: ::in_port_t,
        pub sin6_flowinfo: u32,
        pub sin6_addr: ::in6_addr,
        pub sin6_scope_id: u32,
    }

    #[repr(C)]
    pub struct addrinfo {
        pub ai_flags: ::c_int,
        pub ai_family: ::c_int,
        pub ai_socktype: ::c_int,
        pub ai_protocol: ::c_int,
        pub ai_addrlen: socklen_t,
        pub ai_addr: *mut ::sockaddr,
        pub ai_canonname: *mut ::c_char,
        pub ai_next: *mut ::addrinfo,
    }

    #[repr(C)]
    pub struct sockaddr_ll {
        pub sll_family: ::c_ushort,
        pub sll_protocol: ::c_ushort,
        pub sll_ifindex: ::c_int,
        pub sll_hatype: ::c_ushort,
        pub sll_pkttype: ::c_uchar,
        pub sll_halen: ::c_uchar,
        pub sll_addr: [::c_uchar; 8]
    }

    #[repr(C)]
    pub struct sockaddr_storage {
        pub ss_family: sa_family_t,
        __ss_align: ::size_t,
        #[cfg(target_pointer_width = "32")]
        __ss_pad2: [u8; 128 - 2 * 4],
        #[cfg(target_pointer_width = "64")]
        __ss_pad2: [u8; 128 - 2 * 8],
    }

    #[repr(C)]
    #[repr(align(4))]
    pub struct ifaddrs {
        pub ifa_next: *mut ifaddrs,
        pub ifa_name: *mut ::c_char,
        pub ifa_flags: ::c_int,
        pub ifa_addr: *mut ::sockaddr,
        pub ifa_netmask: *mut ::sockaddr,
        pub ifu_broadaddr_or_dstaddr: *mut ::sockaddr,
        pub ifa_data: *mut ::c_uchar,
    }

    #[repr(C)]
    #[repr(align(4))]
    pub struct msghdr {
        pub msg_name: *mut ::c_uchar,
        pub msg_namelen: ::socklen_t,
        pub msg_iov: *mut ::iovec,
        pub msg_iovlen: ::size_t,
        pub msg_control: *mut ::c_uchar,
        pub msg_controllen: ::socklen_t,
        pub msg_flags: ::c_int,
    }

    #[repr(C)]
    pub struct group_filter {
        pub gf_interface: u32,
        pub gf_group: ::sockaddr_storage,
        pub gf_fmode: u32,
        pub gf_numsrc: u32,
        pub gf_slist: [::sockaddr_storage; 1],
    }

    #[repr(C)]
    pub struct group_req {
        pub gr_interface: u32,
        pub gr_group: ::sockaddr_storage,
    }

    #[repr(C)]
    pub struct group_source_req {
        pub gsr_interface: u32,
        pub gsr_group: ::sockaddr_storage,
        pub gsr_source: ::sockaddr_storage,
    }

    #[repr(C)]
    pub struct in_pktinfo {
        pub ipi_ifindex: ::c_int,
        pub ipi_spec_dst: ::in_addr,
        pub ipi_addr: ::in_addr,
    }

    #[repr(C)]
    pub struct ip6_mtuinfo {
        pub ip6m_addr: ::sockaddr_in6,
        pub ip6m_mtu: u32,
    }

    #[repr(C)]
    pub struct in6_pktinfo {
        pub ipi6_addr: ::in6_addr,
        pub ipi6_ifindex: ::c_uint,
    }

    #[repr(C)]
    pub struct ip_mreq_source {
        pub imr_multiaddr: ::in_addr,
        pub imr_interface: ::in_addr,
        pub imr_sourceaddr: ::in_addr,
    }

    #[repr(C)]
    pub struct ip_mreq {
        pub imr_multiaddr: ::in_addr,
        pub imr_interface: ::in_addr,
    }

    #[repr(C)]
    pub struct ip_mreqn {
        pub imr_multiaddr: ::in_addr,
        pub imr_address: ::in_addr,
        pub imr_ifindex: ::c_int,
    }

    #[repr(C)]
    pub struct ip_msfilter {
        pub imsf_multiaddr: ::in_addr,
        pub imsf_interface: ::in_addr,
        pub imsf_fmode: u32,
        pub imsf_numsrc: u32,
        pub imsf_slist: [::in_addr; 1],
    }

    #[repr(C)]
    pub struct ip_opts {
        pub ip_dst: ::in_addr,
        pub ip_opts: [::c_char; 40],
    }

    #[repr(C)]
    pub struct ipv6_mreq {
        pub ipv6mr_multiaddr: ::in6_addr,
        pub ipv6mr_interface: ::c_uint,
    }

    #[repr(C)]
    pub struct sock_filter {
        pub code: u16,
        pub jt: u8,
        pub jf: u8,
        pub k: u32,
    }

    #[repr(C)]
    pub struct sock_fprog {
        pub len: ::c_ushort,
        pub filter: *mut sock_filter,
    }

    #[repr(C)]
    pub struct pthread_attr_t {
        #[cfg(target_pointer_width = "32")]
        __size: [u32; 8],
        #[cfg(target_pointer_width = "64")]
        __size: [u64; 7],
    }

    #[repr(C)]
    pub struct sigset_t {
        #[cfg(target_pointer_width = "32")]
        __val: [u32; 2],
        #[cfg(target_pointer_width = "64")]
        __val: [u64; 1],
    }

    #[repr(C)]
    pub struct siginfo_t {
        pub si_signo: ::c_int,
        pub si_errno: ::c_int,
        pub si_code: ::c_int,
        _pad: [::c_int; 31],
        _align: [u64; 0],
    }

    #[repr(C)]
    pub struct sigaction {
        pub sa_sigaction: ::sighandler_t,
        pub sa_mask: ::sigset_t,
        pub sa_flags: ::c_int,
        pub sa_restorer: ::Option<extern fn()>,
    }

    pub struct linger {
        pub l_onoff: ::c_int,
        pub l_linger: ::c_int,
    }

    pub struct sched_param {
        pub sched_priority: ::c_int,
        pub sched_ss_low_priority: ::c_int,
        pub sched_ss_repl_period: ::timespec,
        pub sched_ss_init_budget: ::timespec,
        pub sched_ss_max_repl: ::c_int,
    }

    pub struct posix_spawn_file_actions_t {
        __allocated: ::c_int,
        __used: ::c_int,
        __actions: *mut ::c_int,
        __pad: [::c_int; 16],
    }

    pub struct posix_spawnattr_t {
        __flags: ::c_short,
        __pgrp: ::pid_t,
        __sd: ::sigset_t,
        __ss: ::sigset_t,
        __prio: ::c_int,
        __policy: ::c_int,
        __pad: [::c_int; 16],
    }
}

pub const PTHREAD_STACK_MIN: ::size_t = 2048;

pub const __WASI_SDFLAGS_RD: ::c_int = 1;
pub const __WASI_SDFLAGS_WR: ::c_int = 2;

pub const SHUT_RD: ::c_int = __WASI_SDFLAGS_RD;
pub const SHUT_WR: ::c_int = __WASI_SDFLAGS_WR;
pub const SHUT_RDWR: ::c_int = SHUT_RD | SHUT_WR;

pub const __WASI_RIFLAGS_RECV_PEEK: ::c_int = 1;
pub const __WASI_RIFLAGS_RECV_WAITALL: ::c_int = 2;
pub const __WASI_RIFLAGS_RECV_DATA_TRUNCATED: ::c_int = 4;

pub const MSG_OOB: ::c_int = 0x0001;
pub const MSG_PEEK: ::c_int = 0x0002;
pub const MSG_DONTROUTE: ::c_int = 0x0004;
pub const MSG_CTRUNC: ::c_int = 0x0008;
pub const MSG_PROXY: ::c_int = 0x0010;
pub const MSG_TRUNC: ::c_int = 0x0020;
pub const MSG_DONTWAIT: ::c_int = 0x0040;
pub const MSG_EOR: ::c_int = 0x0080;
pub const MSG_WAITALL: ::c_int = 0x0100;
pub const MSG_FIN: ::c_int = 0x0200;
pub const MSG_SYN: ::c_int = 0x0400;
pub const MSG_CONFIRM: ::c_int = 0x0800;
pub const MSG_RST: ::c_int = 0x1000;
pub const MSG_ERRQUEUE: ::c_int = 0x2000;
pub const MSG_NOSIGNAL: ::c_int = 0x4000;
pub const MSG_MORE: ::c_int = 0x8000;
pub const MSG_WAITFORONE: ::c_int = 0x10000;
pub const MSG_BATCH: ::c_int = 0x40000;
pub const MSG_ZEROCOPY: ::c_int = 0x4000000;
pub const MSG_FASTOPEN: ::c_int = 0x20000000;
pub const MSG_CMSG_CLOEXEC: ::c_int = 0x40000000;

pub const __WASI_FILETYPE_UNKNOWN: ::c_int = 0;
pub const __WASI_FILETYPE_BLOCK_DEVICE: ::c_int = 1;
pub const __WASI_FILETYPE_CHARACTER_DEVICE: ::c_int = 2;
pub const __WASI_FILETYPE_DIRECTORY: ::c_int = 3;
pub const __WASI_FILETYPE_REGULAR_FILE: ::c_int = 4;
pub const __WASI_FILETYPE_SOCKET_DGRAM: ::c_int = 5;
pub const __WASI_FILETYPE_SOCKET_STREAM: ::c_int = 6;
pub const __WASI_FILETYPE_SYMBOLIC_LINK: ::c_int = 7;
pub const __WASI_FILETYPE_SOCKET_RAW: ::c_int = 8;
pub const __WASI_FILETYPE_SOCKET_SEQPACKET: ::c_int = 9;

pub const __WASI_SOCK_TYPE_SOCKET_UNUSED: ::c_int = 0;
pub const __WASI_SOCK_TYPE_SOCKET_STREAM: ::c_int = 1;
pub const __WASI_SOCK_TYPE_SOCKET_DGRAM: ::c_int = 2;
pub const __WASI_SOCK_TYPE_SOCKET_RAW: ::c_int = 3;
pub const __WASI_SOCK_TYPE_SOCKET_SEQPACKET: ::c_int = 4;

pub const SOCK_DGRAM: ::c_int = __WASI_SOCK_TYPE_SOCKET_DGRAM;
pub const SOCK_STREAM: ::c_int = __WASI_SOCK_TYPE_SOCKET_STREAM;
pub const SOCK_RAW: ::c_int = __WASI_SOCK_TYPE_SOCKET_RAW;
pub const SOCK_SEQPACKET: ::c_int = __WASI_SOCK_TYPE_SOCKET_SEQPACKET;

pub const SOCK_NONBLOCK: ::c_int = 0x00004000;
pub const SOCK_CLOEXEC: ::c_int = 0x00002000;

pub const SOL_SOCKET: ::c_int = 0x7fffffff;
pub const SOL_IP: ::c_int = IPPROTO_IP;
pub const SOL_ICMP: ::c_int = IPPROTO_ICMP;
pub const SOL_IGMP: ::c_int = IPPROTO_IGMP;
pub const SOL_IPIP: ::c_int = IPPROTO_IPIP;
pub const SOL_TCP: ::c_int = IPPROTO_TCP;
pub const SOL_EGP: ::c_int = IPPROTO_EGP;
pub const SOL_PUP: ::c_int = IPPROTO_PUP;
pub const SOL_UDP: ::c_int = IPPROTO_UDP;
pub const SOL_IDP: ::c_int = IPPROTO_IDP;
pub const SOL_TP: ::c_int = IPPROTO_TP;
pub const SOL_DCCP: ::c_int = IPPROTO_DCCP;
pub const SOL_IPV6: ::c_int = IPPROTO_IPV6;
pub const SOL_ROUTING: ::c_int = IPPROTO_ROUTING;
pub const SOL_FRAGMENT: ::c_int = IPPROTO_FRAGMENT;
pub const SOL_RSVP: ::c_int = IPPROTO_RSVP;
pub const SOL_GRE: ::c_int = IPPROTO_GRE;
pub const SOL_ESP: ::c_int = IPPROTO_ESP;
pub const SOL_AH: ::c_int = IPPROTO_AH;
pub const SOL_ICMPV6: ::c_int = IPPROTO_ICMPV6;
pub const SOL_NONE: ::c_int = IPPROTO_NONE;
pub const SOL_DSTOPTS: ::c_int = IPPROTO_DSTOPTS;
pub const SOL_MTP: ::c_int = IPPROTO_MTP;
pub const SOL_BEETPH: ::c_int = IPPROTO_BEETPH;
pub const SOL_ENCAP: ::c_int = IPPROTO_ENCAP;
pub const SOL_PIM: ::c_int = IPPROTO_PIM;
pub const SOL_COMP: ::c_int = IPPROTO_COMP;
pub const SOL_SCTP: ::c_int = IPPROTO_SCTP;
pub const SOL_MH: ::c_int = IPPROTO_MH;
pub const SOL_UDPLITE: ::c_int = IPPROTO_UDPLITE;
pub const SOL_MPLS: ::c_int = IPPROTO_MPLS;
pub const SOL_ETHERNET: ::c_int = IPPROTO_ETHERNET;
pub const SOL_MPTCP: ::c_int = IPPROTO_MPTCP;

pub const __WASI_SOCK_OPTION_NOOP: ::c_int = 0;
pub const __WASI_SOCK_OPTION_REUSE_PORT: ::c_int = 1;
pub const __WASI_SOCK_OPTION_REUSE_ADDR: ::c_int = 2;
pub const __WASI_SOCK_OPTION_NO_DELAY: ::c_int = 3;
pub const __WASI_SOCK_OPTION_DONT_ROUTE: ::c_int = 4;
pub const __WASI_SOCK_OPTION_ONLY_V6: ::c_int = 5;
pub const __WASI_SOCK_OPTION_BROADCAST: ::c_int = 6;
pub const __WASI_SOCK_OPTION_MULTICAST_LOOP_V4: ::c_int = 7;
pub const __WASI_SOCK_OPTION_MULTICAST_LOOP_V6: ::c_int = 8;
pub const __WASI_SOCK_OPTION_PROMISCUOUS: ::c_int = 9;
pub const __WASI_SOCK_OPTION_LISTENING: ::c_int = 10;
pub const __WASI_SOCK_OPTION_LAST_ERROR: ::c_int = 11;
pub const __WASI_SOCK_OPTION_KEEP_ALIVE: ::c_int = 12;
pub const __WASI_SOCK_OPTION_LINGER: ::c_int = 13;
pub const __WASI_SOCK_OPTION_OOB_INLINE: ::c_int = 14;
pub const __WASI_SOCK_OPTION_RECV_BUF_SIZE: ::c_int = 15;
pub const __WASI_SOCK_OPTION_SEND_BUF_SIZE: ::c_int = 16;
pub const __WASI_SOCK_OPTION_RECV_LOWAT: ::c_int = 17;
pub const __WASI_SOCK_OPTION_SEND_LOWAT: ::c_int = 18;
pub const __WASI_SOCK_OPTION_RECV_TIMEOUT: ::c_int = 19;
pub const __WASI_SOCK_OPTION_SEND_TIMEOUT: ::c_int = 20;
pub const __WASI_SOCK_OPTION_CONNECT_TIMEOUT: ::c_int = 21;
pub const __WASI_SOCK_OPTION_ACCEPT_TIMEOUT: ::c_int = 22;
pub const __WASI_SOCK_OPTION_TTL: ::c_int = 23;
pub const __WASI_SOCK_OPTION_MULTICAST_TTL_V4: ::c_int = 24;
pub const __WASI_SOCK_OPTION_TYPE: ::c_int = 25;
pub const __WASI_SOCK_OPTION_PROTO: ::c_int = 26;

pub const SO_ACCEPTCONN: ::c_int = __WASI_SOCK_OPTION_LISTENING;
pub const SO_BROADCAST: ::c_int = __WASI_SOCK_OPTION_BROADCAST;
pub const SO_DONTROUTE: ::c_int = __WASI_SOCK_OPTION_DONT_ROUTE;
pub const SO_NODELAY: ::c_int = __WASI_SOCK_OPTION_NO_DELAY;
pub const SO_ERROR: ::c_int = __WASI_SOCK_OPTION_LAST_ERROR;
pub const SO_KEEPALIVE: ::c_int = __WASI_SOCK_OPTION_KEEP_ALIVE;
pub const SO_LINGER: ::c_int = __WASI_SOCK_OPTION_LINGER;
pub const SO_OOBINLINE: ::c_int = __WASI_SOCK_OPTION_OOB_INLINE;
pub const SO_ONLYV6: ::c_int = __WASI_SOCK_OPTION_ONLY_V6;
pub const SO_RCVBUF: ::c_int = __WASI_SOCK_OPTION_RECV_BUF_SIZE;
pub const SO_RCVLOWAT: ::c_int = __WASI_SOCK_OPTION_RECV_LOWAT;
pub const SO_RCVTIMEO: ::c_int = __WASI_SOCK_OPTION_RECV_TIMEOUT;
pub const SO_REUSEPORT: ::c_int = __WASI_SOCK_OPTION_REUSE_PORT;
pub const SO_REUSEADDR: ::c_int = __WASI_SOCK_OPTION_REUSE_ADDR;
pub const SO_SNDBUF: ::c_int = __WASI_SOCK_OPTION_SEND_BUF_SIZE;
pub const SO_SNDLOWAT: ::c_int = __WASI_SOCK_OPTION_SEND_LOWAT;
pub const SO_SNDTIMEO: ::c_int = __WASI_SOCK_OPTION_SEND_TIMEOUT;
pub const SO_MCASTLOOPV4: ::c_int = __WASI_SOCK_OPTION_MULTICAST_LOOP_V4;
pub const SO_MCASTLOOPV6: ::c_int = __WASI_SOCK_OPTION_MULTICAST_LOOP_V6;
pub const SO_CONNTIMEO: ::c_int = __WASI_SOCK_OPTION_CONNECT_TIMEOUT;
pub const SO_ACCPTIMEO: ::c_int = __WASI_SOCK_OPTION_ACCEPT_TIMEOUT;
pub const SO_TTL: ::c_int = __WASI_SOCK_OPTION_TTL;
pub const SO_MCASTTTLV4: ::c_int = __WASI_SOCK_OPTION_MULTICAST_TTL_V4;
pub const SO_TYPE: ::c_int = __WASI_SOCK_OPTION_TYPE;
pub const SO_PROTOCOL: ::c_int = __WASI_SOCK_OPTION_PROTO;
pub const SO_MARK: ::c_int = __WASI_SOCK_OPTION_NOOP;
pub const SO_BINDTODEVICE: ::c_int = __WASI_SOCK_OPTION_NOOP;
pub const SO_INCOMING_CPU: ::c_int = __WASI_SOCK_OPTION_NOOP;
pub const SO_ATTACH_FILTER: ::c_int = __WASI_SOCK_OPTION_NOOP;
pub const SO_DETACH_FILTER: ::c_int = __WASI_SOCK_OPTION_NOOP;

pub const AF_UNSPEC: ::c_int = 0;
pub const AF_INET: ::c_int = 1;
pub const AF_INET6: ::c_int = 2;
pub const AF_UNIX: ::c_int = 3;

pub const IF_NAMESIZE: ::size_t = 16;
pub const IFNAMSIZ: ::size_t = IF_NAMESIZE;

pub const IPPROTO_IP: ::c_int = 0;
pub const IPPROTO_HOPOPTS: ::c_int = 0;
pub const IPPROTO_ICMP: ::c_int = 1;
pub const IPPROTO_IGMP: ::c_int = 2;
pub const IPPROTO_IPIP: ::c_int = 4;
pub const IPPROTO_TCP: ::c_int = 6;
pub const IPPROTO_EGP: ::c_int = 8;
pub const IPPROTO_PUP: ::c_int = 12;
pub const IPPROTO_UDP: ::c_int = 17;
pub const IPPROTO_IDP: ::c_int = 22;
pub const IPPROTO_TP: ::c_int = 29;
pub const IPPROTO_DCCP: ::c_int = 33;
pub const IPPROTO_IPV6: ::c_int = 41;
pub const IPPROTO_ROUTING: ::c_int = 43;
pub const IPPROTO_FRAGMENT: ::c_int = 44;
pub const IPPROTO_RSVP: ::c_int = 46;
pub const IPPROTO_GRE: ::c_int = 47;
pub const IPPROTO_ESP: ::c_int = 50;
pub const IPPROTO_AH: ::c_int = 51;
pub const IPPROTO_ICMPV6: ::c_int = 58;
pub const IPPROTO_NONE: ::c_int = 59;
pub const IPPROTO_DSTOPTS: ::c_int = 60;
pub const IPPROTO_MTP: ::c_int = 92;
pub const IPPROTO_BEETPH: ::c_int = 94;
pub const IPPROTO_ENCAP: ::c_int = 98;
pub const IPPROTO_PIM: ::c_int = 103;
pub const IPPROTO_COMP: ::c_int = 108;
pub const IPPROTO_SCTP: ::c_int = 132;
pub const IPPROTO_MH: ::c_int = 135;
pub const IPPROTO_UDPLITE: ::c_int = 136;
pub const IPPROTO_MPLS: ::c_int = 137;
pub const IPPROTO_ETHERNET: ::c_int = 143;
pub const IPPROTO_RAW: ::c_int = 255;
pub const IPPROTO_MPTCP: ::c_int = 262;
pub const IPPROTO_MAX: ::c_int = 263;

pub const IP_TOS: ::c_int = 1;
pub const IP_TTL: ::c_int = 2;
pub const IP_HDRINCL: ::c_int = 3;
pub const IP_OPTIONS: ::c_int = 4;
pub const IP_ROUTER_ALERT: ::c_int = 5;
pub const IP_RECVOPTS: ::c_int = 6;
pub const IP_RETOPTS: ::c_int = 7;
pub const IP_PKTINFO: ::c_int = 8;
pub const IP_PKTOPTIONS: ::c_int = 9;
pub const IP_PMTUDISC: ::c_int = 10;
pub const IP_MTU_DISCOVER: ::c_int = 10;
pub const IP_RECVERR: ::c_int = 11;
pub const IP_RECVTTL: ::c_int = 12;
pub const IP_RECVTOS: ::c_int = 13;
pub const IP_MTU: ::c_int = 14;
pub const IP_FREEBIND: ::c_int = 15;
pub const IP_IPSEC_POLICY: ::c_int = 16;
pub const IP_XFRM_POLICY: ::c_int = 17;
pub const IP_PASSSEC: ::c_int = 18;
pub const IP_TRANSPARENT: ::c_int = 19;
pub const IP_ORIGDSTADDR: ::c_int = 20;
pub const IP_RECVORIGDSTADDR: ::c_int = IP_ORIGDSTADDR;
pub const IP_MINTTL: ::c_int = 21;
pub const IP_NODEFRAG: ::c_int = 22;
pub const IP_CHECKSUM: ::c_int = 23;
pub const IP_BIND_ADDRESS_NO_PORT: ::c_int = 24;
pub const IP_RECVFRAGSIZE: ::c_int = 25;
pub const IP_RECVERR_RFC4884: ::c_int = 26;
pub const IP_MULTICAST_IF: ::c_int = 32;
pub const IP_MULTICAST_TTL: ::c_int = 33;
pub const IP_MULTICAST_LOOP: ::c_int = 34;
pub const IP_ADD_MEMBERSHIP: ::c_int = 35;
pub const IP_DROP_MEMBERSHIP: ::c_int = 36;
pub const IP_UNBLOCK_SOURCE: ::c_int = 37;
pub const IP_BLOCK_SOURCE: ::c_int = 38;
pub const IP_ADD_SOURCE_MEMBERSHIP: ::c_int = 39;
pub const IP_DROP_SOURCE_MEMBERSHIP: ::c_int = 40;
pub const IP_MSFILTER: ::c_int = 41;
pub const IP_MULTICAST_ALL: ::c_int = 49;
pub const IP_UNICAST_IF: ::c_int = 50;

pub const IP_RECVRETOPTS: ::c_int = IP_RETOPTS;

pub const IP_PMTUDISC_DONT: ::c_int = 0;
pub const IP_PMTUDISC_WANT: ::c_int = 1;
pub const IP_PMTUDISC_DO: ::c_int = 2;
pub const IP_PMTUDISC_PROBE: ::c_int = 3;
pub const IP_PMTUDISC_INTERFACE: ::c_int = 4;
pub const IP_PMTUDISC_OMIT: ::c_int = 5;

pub const IP_DEFAULT_MULTICAST_TTL: ::c_int = 1;
pub const IP_DEFAULT_MULTICAST_LOOP: ::c_int = 1;
pub const IP_MAX_MEMBERSHIPS: ::c_int = 20;

pub const MCAST_JOIN_GROUP: ::c_int = 42;
pub const MCAST_BLOCK_SOURCE: ::c_int = 43;
pub const MCAST_UNBLOCK_SOURCE: ::c_int = 44;
pub const MCAST_LEAVE_GROUP: ::c_int = 45;
pub const MCAST_JOIN_SOURCE_GROUP: ::c_int = 46;
pub const MCAST_LEAVE_SOURCE_GROUP: ::c_int = 47;
pub const MCAST_MSFILTER: ::c_int = 48;

pub const MCAST_EXCLUDE: ::c_int = 0;
pub const MCAST_INCLUDE: ::c_int = 1;

pub const IPV6_ADDRFORM: ::c_int = 1;
pub const IPV6_2292PKTINFO: ::c_int = 2;
pub const IPV6_2292HOPOPTS: ::c_int = 3;
pub const IPV6_2292DSTOPTS: ::c_int = 4;
pub const IPV6_2292RTHDR: ::c_int = 5;
pub const IPV6_2292PKTOPTIONS: ::c_int = 6;
pub const IPV6_CHECKSUM: ::c_int = 7;
pub const IPV6_2292HOPLIMIT: ::c_int = 8;
pub const IPV6_NEXTHOP: ::c_int = 9;
pub const IPV6_AUTHHDR: ::c_int = 10;
pub const IPV6_UNICAST_HOPS: ::c_int = 16;
pub const IPV6_MULTICAST_IF: ::c_int = 17;
pub const IPV6_MULTICAST_HOPS: ::c_int = 18;
pub const IPV6_MULTICAST_LOOP: ::c_int = 19;
pub const IPV6_JOIN_GROUP: ::c_int = 20;
pub const IPV6_LEAVE_GROUP: ::c_int = 21;
pub const IPV6_ROUTER_ALERT: ::c_int = 22;
pub const IPV6_MTU_DISCOVER: ::c_int = 23;
pub const IPV6_MTU: ::c_int = 24;
pub const IPV6_RECVERR: ::c_int = 25;
pub const IPV6_V6ONLY: ::c_int = 26;
pub const IPV6_JOIN_ANYCAST: ::c_int = 27;
pub const IPV6_LEAVE_ANYCAST: ::c_int = 28;
pub const IPV6_MULTICAST_ALL: ::c_int = 29;
pub const IPV6_ROUTER_ALERT_ISOLATE: ::c_int = 30;
pub const IPV6_IPSEC_POLICY: ::c_int = 34;
pub const IPV6_XFRM_POLICY: ::c_int = 35;
pub const IPV6_HDRINCL: ::c_int = 36;

pub const IPV6_RECVPKTINFO: ::c_int = 49;
pub const IPV6_PKTINFO: ::c_int = 50;
pub const IPV6_RECVHOPLIMIT: ::c_int = 51;
pub const IPV6_HOPLIMIT: ::c_int = 52;
pub const IPV6_RECVHOPOPTS: ::c_int = 53;
pub const IPV6_HOPOPTS: ::c_int = 54;
pub const IPV6_RTHDRDSTOPTS: ::c_int = 55;
pub const IPV6_RECVRTHDR: ::c_int = 56;
pub const IPV6_RTHDR: ::c_int = 57;
pub const IPV6_RECVDSTOPTS: ::c_int = 58;
pub const IPV6_DSTOPTS: ::c_int = 59;
pub const IPV6_RECVPATHMTU: ::c_int = 60;
pub const IPV6_PATHMTU: ::c_int = 61;
pub const IPV6_DONTFRAG: ::c_int = 62;
pub const IPV6_RECVTCLASS: ::c_int = 66;
pub const IPV6_TCLASS: ::c_int = 67;
pub const IPV6_AUTOFLOWLABEL: ::c_int = 70;
pub const IPV6_ADDR_PREFERENCES: ::c_int = 72;
pub const IPV6_MINHOPCOUNT: ::c_int = 73;
pub const IPV6_ORIGDSTADDR: ::c_int = 74;
pub const IPV6_RECVORIGDSTADDR: ::c_int = IPV6_ORIGDSTADDR;
pub const IPV6_TRANSPARENT: ::c_int = 75;
pub const IPV6_UNICAST_IF: ::c_int = 76;
pub const IPV6_RECVFRAGSIZE: ::c_int = 77;
pub const IPV6_FREEBIND: ::c_int = 78;

pub const IPV6_ADD_MEMBERSHIP: ::c_int = IPV6_JOIN_GROUP;
pub const IPV6_DROP_MEMBERSHIP: ::c_int = IPV6_LEAVE_GROUP;
pub const IPV6_RXHOPOPTS: ::c_int = IPV6_HOPOPTS;
pub const IPV6_RXDSTOPTS: ::c_int = IPV6_DSTOPTS;

pub const IPV6_PMTUDISC_DONT: ::c_int = 0;
pub const IPV6_PMTUDISC_WANT: ::c_int = 1;
pub const IPV6_PMTUDISC_DO: ::c_int = 2;
pub const IPV6_PMTUDISC_PROBE: ::c_int = 3;
pub const IPV6_PMTUDISC_INTERFACE: ::c_int = 4;
pub const IPV6_PMTUDISC_OMIT: ::c_int = 5;

pub const IPV6_PREFER_SRC_TMP: ::c_int = 0x0001;
pub const IPV6_PREFER_SRC_PUBLIC: ::c_int = 0x0002;
pub const IPV6_PREFER_SRC_PUBTMP_DEFAULT: ::c_int = 0x0100;
pub const IPV6_PREFER_SRC_COA: ::c_int = 0x0004;
pub const IPV6_PREFER_SRC_HOME: ::c_int = 0x0400;
pub const IPV6_PREFER_SRC_CGA: ::c_int = 0x0008;
pub const IPV6_PREFER_SRC_NONCGA: ::c_int = 0x0800;

pub const IPV6_RTHDR_LOOSE: ::c_int = 0;
pub const IPV6_RTHDR_STRICT: ::c_int = 1;

pub const IPV6_RTHDR_TYPE_0: ::c_int = 0;

pub const TCP_NODELAY: ::c_int = 1;
pub const TCP_MAXSEG: ::c_int = 2;
pub const TCP_CORK: ::c_int = 3;
pub const TCP_KEEPIDLE: ::c_int = 4;
pub const TCP_KEEPINTVL: ::c_int = 5;
pub const TCP_KEEPCNT: ::c_int = 6;
pub const TCP_SYNCNT: ::c_int = 7;
pub const TCP_LINGER2: ::c_int = 8;
pub const TCP_DEFER_ACCEPT: ::c_int = 9;
pub const TCP_WINDOW_CLAMP: ::c_int = 10;
pub const TCP_INFO: ::c_int = 11;
pub const TCP_QUICKACK: ::c_int = 12;
pub const TCP_CONGESTION: ::c_int = 13;
pub const TCP_MD5SIG: ::c_int = 14;
pub const TCP_THIN_LINEAR_TIMEOUTS: ::c_int = 16;
pub const TCP_THIN_DUPACK: ::c_int = 17;
pub const TCP_USER_TIMEOUT: ::c_int = 18;
pub const TCP_REPAIR: ::c_int = 19;
pub const TCP_REPAIR_QUEUE: ::c_int = 20;
pub const TCP_QUEUE_SEQ: ::c_int = 21;
pub const TCP_REPAIR_OPTIONS: ::c_int = 22;
pub const TCP_FASTOPEN: ::c_int = 23;
pub const TCP_TIMESTAMP: ::c_int = 24;
pub const TCP_NOTSENT_LOWAT: ::c_int = 25;
pub const TCP_CC_INFO: ::c_int = 26;
pub const TCP_SAVE_SYN: ::c_int = 27;
pub const TCP_SAVED_SYN: ::c_int = 28;
pub const TCP_REPAIR_WINDOW: ::c_int = 29;
pub const TCP_FASTOPEN_CONNECT: ::c_int = 30;
pub const TCP_ULP: ::c_int = 31;
pub const TCP_MD5SIG_EXT: ::c_int = 32;
pub const TCP_FASTOPEN_KEY: ::c_int = 33;
pub const TCP_FASTOPEN_NO_COOKIE: ::c_int = 34;
pub const TCP_ZEROCOPY_RECEIVE: ::c_int = 35;
pub const TCP_INQ: ::c_int = 36;
pub const TCP_TX_DELAY: ::c_int = 37;

pub const TCP_CM_INQ: ::c_int = TCP_INQ;

pub const TCP_ESTABLISHED: ::c_int = 1;
pub const TCP_SYN_SENT: ::c_int = 2;
pub const TCP_SYN_RECV: ::c_int = 3;
pub const TCP_FIN_WAIT1: ::c_int = 4;
pub const TCP_FIN_WAIT2: ::c_int = 5;
pub const TCP_TIME_WAIT: ::c_int = 6;
pub const TCP_CLOSE: ::c_int = 7;
pub const TCP_CLOSE_WAIT: ::c_int = 8;
pub const TCP_LAST_ACK: ::c_int = 9;
pub const TCP_LISTEN: ::c_int = 10;
pub const TCP_CLOSING: ::c_int = 11;

pub const PRIO_MIN: ::c_int = -20;
pub const PRIO_MAX: ::c_int = 20;

pub const INADDR_LOOPBACK: in_addr_t = 2130706433;
pub const INADDR_ANY: in_addr_t = 0;
pub const INADDR_BROADCAST: in_addr_t = 4294967295;
pub const INADDR_NONE: in_addr_t = 4294967295;

pub const INADDR_UNSPEC_GROUP: in_addr_t = 0xe0000000;
pub const INADDR_ALLHOSTS_GROUP: in_addr_t = 0xe0000001;
pub const INADDR_ALLRTRS_GROUP: in_addr_t = 0xe0000002;
pub const INADDR_ALLSNOOPERS_GROUP: in_addr_t = 0xe000006a;
pub const INADDR_MAX_LOCAL_GROUP: in_addr_t = 0xe00000ff;

pub const ARPOP_REQUEST: u16 = 1;
pub const ARPOP_REPLY: u16 = 2;

pub const POSIX_SPAWN_RESETIDS: ::c_int = 0x01;
pub const POSIX_SPAWN_SETPGROUP: ::c_int = 0x02;
pub const POSIX_SPAWN_SETSIGDEF: ::c_int = 0x04;
pub const POSIX_SPAWN_SETSIGMASK: ::c_int = 0x08;
pub const POSIX_SPAWN_SETSCHEDPARAM: ::c_int = 0x10;
pub const POSIX_SPAWN_SETSCHEDULER: ::c_int = 0x20;

pub const WNOHANG: ::c_int = 0x00000001;
pub const WUNTRACED: ::c_int = 0x00000002;
pub const WSTOPPED: ::c_int = WUNTRACED;
pub const WEXITED: ::c_int = 0x00000004;
pub const WCONTINUED: ::c_int = 0x00000008;
pub const WNOWAIT: ::c_int = 0x01000000;

pub const SIG_DFL: sighandler_t = 0 as sighandler_t;
pub const SIG_IGN: sighandler_t = 1 as sighandler_t;
pub const SIG_ERR: sighandler_t = !0 as sighandler_t;

pub const SIGHUP: ::c_int = 1;
pub const SIGINT: ::c_int = 2;
pub const SIGQUIT: ::c_int = 3;
pub const SIGILL: ::c_int = 4;
pub const SIGTRAP: ::c_int = 5;
pub const SIGABRT: ::c_int = 6;
pub const SIGBUS: ::c_int = 7;
pub const SIGFPE: ::c_int = 8;
pub const SIGKILL: ::c_int = 9;
pub const SIGUSR1: ::c_int = 10;
pub const SIGSEGV: ::c_int = 11;
pub const SIGUSR2: ::c_int = 12;
pub const SIGPIPE: ::c_int = 13;
pub const SIGALRM: ::c_int = 14;
pub const SIGTERM: ::c_int = 15;
pub const SIGSTKFLT: ::c_int = 16;
pub const SIGCHLD: ::c_int = 17;
pub const SIGCONT: ::c_int = 18;
pub const SIGSTOP: ::c_int = 19;
pub const SIGTSTP: ::c_int = 20;
pub const SIGTTIN: ::c_int = 21;
pub const SIGTTOU: ::c_int = 22;
pub const SIGURG: ::c_int = 23;
pub const SIGXCPU: ::c_int = 24;
pub const SIGXFSZ: ::c_int = 25;
pub const SIGVTALRM: ::c_int = 26;
pub const SIGPROF: ::c_int = 27;
pub const SIGWINCH: ::c_int = 28;
pub const SIGIO: ::c_int = 29;
pub const SIGPOLL: ::c_int = 29;
pub const SIGPWR: ::c_int = 30;
pub const SIGSYS: ::c_int = 31;

pub const SIG_BLOCK: ::c_int = 0;
pub const SIG_UNBLOCK: ::c_int = 1;
pub const SIG_SETMASK: ::c_int = 2;

pub const SA_NOCLDSTOP: ::c_int = 1;
pub const SA_NOCLDWAIT: ::c_int = 2;
pub const SA_SIGINFO: ::c_int = 4;
pub const SA_ONSTACK: ::c_int = 0x08000000;
pub const SA_RESTART: ::c_int = 0x10000000;
pub const SA_NODEFER: ::c_int = 0x40000000;
pub const SA_RESETHAND: ::c_int = 0x80000000;
pub const SA_RESTORER: ::c_int = 0x04000000;

#[cfg_attr(
    feature = "rustc-dep-of-std",
    link(
        name = "c",
        kind = "static",
        modifiers = "-bundle",
        cfg(target_feature = "crt-static")
    )
)]
#[cfg_attr(
    feature = "rustc-dep-of-std",
    link(name = "c", cfg(not(target_feature = "crt-static")))
)]
extern "C" {
    pub fn dup(fd: ::c_int) -> ::c_int;
    pub fn dup2(src: ::c_int, dst: ::c_int) -> ::c_int;

    pub fn accept(socket: ::c_int, addr: *mut sockaddr, addrlen: *mut socklen_t) -> ::c_int;
    pub fn accept4(
        socket: ::c_int,
        addr: *mut sockaddr,
        addrlen: *mut socklen_t,
        flags: ::c_int,
    ) -> ::c_int;
    pub fn bind(socket: ::c_int, addr: *const ::sockaddr, addrlen: ::socklen_t) -> ::c_int;
    pub fn connect(socket: ::c_int, addr: *const sockaddr, addrlen: socklen_t) -> ::c_int;
    pub fn freeifaddrs(ifa: *mut ::ifaddrs);
    pub fn getifaddrs(ifap: *mut *mut ::ifaddrs) -> ::c_int;
    pub fn getpeername(socket: ::c_int, addr: *mut sockaddr, addrlen: *mut socklen_t) -> ::c_int;
    pub fn getsockname(socket: ::c_int, addr: *mut sockaddr, addrlen: *mut socklen_t) -> ::c_int;
    pub fn getsockopt(
        sockfd: ::c_int,
        level: ::c_int,
        option_name: ::c_int,
        option_value: *mut ::c_void,
        option_len: *mut ::socklen_t,
    ) -> ::c_int;
    pub fn listen(socket: ::c_int, backlog: ::c_int) -> ::c_int;
    pub fn recvfrom(
        socket: ::c_int,
        buffer: *mut ::c_void,
        length: ::size_t,
        flags: ::c_int,
        addr: *mut ::sockaddr,
        addrlen: *mut ::socklen_t,
    ) -> ::ssize_t;
    pub fn recvmsg(socket: ::c_int, msg: *mut ::msghdr, flags: ::c_int) -> ::ssize_t;
    pub fn sendfile(
        socket: ::c_int,
        in_fd: ::c_int,
        ofs: *const ::off_t,
        count: ::size_t,
    ) -> ::ssize_t;
    pub fn sendmsg(socket: ::c_int, msg: *const ::msghdr, flags: ::c_int) -> ::ssize_t;
    pub fn sendto(
        socket: ::c_int,
        buffer: *const ::c_void,
        length: ::size_t,
        flags: ::c_int,
        addr: *const sockaddr,
        addrlen: socklen_t,
    ) -> ::ssize_t;
    pub fn setsockopt(
        socket: ::c_int,
        level: ::c_int,
        option_name: ::c_int,
        option_value: *const ::c_void,
        option_len: socklen_t,
    ) -> ::c_int;
    pub fn socket(domain: ::c_int, ty: ::c_int, protocol: ::c_int) -> ::c_int;
    pub fn socketpair(
        domain: ::c_int,
        ty: ::c_int,
        protocol: ::c_int,
        socket_vector: *mut ::c_int,
    ) -> ::c_int;

    pub fn __wasilibc_initialize_environ();
    pub fn __wasilibc_get_stack_pointer() -> *mut ::c_void;
    pub fn __wasilibc_set_stack_pointer(val: *mut ::c_void);
    pub fn __wasilibc_get_pthread_self() -> *mut ::c_void;
    pub fn __wasilibc_set_pthread_self(val: *mut ::c_void);
    pub fn __wasilibc_init_tls(val: *mut ::c_void);
    pub fn __wasilibc_tls_size() -> u64;
    pub fn __wasilibc_tls_align() -> u64;
    pub fn __wasilibc_get_tls_base() -> *mut ::c_void;
    pub fn __wasilibc_set_tls_base(val: *mut ::c_void);

    pub fn getpid() -> ::pid_t;

    pub fn execl(path: *const ::c_char, arg0: *const ::c_char, ...) -> ::c_int;
    pub fn execle(path: *const ::c_char, arg0: *const ::c_char, ...) -> ::c_int;
    pub fn execlp(file: *const ::c_char, arg0: *const ::c_char, ...) -> ::c_int;
    pub fn execv(prog: *const ::c_char, argv: *const *const ::c_char) -> ::c_int;
    pub fn execve(
        prog: *const ::c_char,
        argv: *const *const ::c_char,
        envp: *const *const ::c_char,
    ) -> ::c_int;
    pub fn execvp(c: *const ::c_char, argv: *const *const ::c_char) -> ::c_int;
    pub fn fork() -> ::pid_t;

    pub fn posix_spawn(
        pid: *mut ::pid_t,
        path: *const ::c_char,
        file_actions: *const ::posix_spawn_file_actions_t,
        attrp: *const ::posix_spawnattr_t,
        argv: *const *mut ::c_char,
        envp: *const *mut ::c_char,
    ) -> ::c_int;
    pub fn posix_spawnp(
        pid: *mut ::pid_t,
        file: *const ::c_char,
        file_actions: *const ::posix_spawn_file_actions_t,
        attrp: *const ::posix_spawnattr_t,
        argv: *const *mut ::c_char,
        envp: *const *mut ::c_char,
    ) -> ::c_int;
    pub fn posix_spawnattr_init(attr: *mut posix_spawnattr_t) -> ::c_int;
    pub fn posix_spawnattr_destroy(attr: *mut posix_spawnattr_t) -> ::c_int;
    pub fn posix_spawnattr_getsigdefault(
        attr: *const posix_spawnattr_t,
        default: *mut ::sigset_t,
    ) -> ::c_int;
    pub fn posix_spawnattr_setsigdefault(
        attr: *mut posix_spawnattr_t,
        default: *const ::sigset_t,
    ) -> ::c_int;
    pub fn posix_spawnattr_getsigmask(
        attr: *const posix_spawnattr_t,
        default: *mut ::sigset_t,
    ) -> ::c_int;
    pub fn posix_spawnattr_setsigmask(
        attr: *mut posix_spawnattr_t,
        default: *const ::sigset_t,
    ) -> ::c_int;
    pub fn posix_spawnattr_getflags(
        attr: *const posix_spawnattr_t,
        flags: *mut ::c_short,
    ) -> ::c_int;
    pub fn posix_spawnattr_setflags(attr: *mut posix_spawnattr_t, flags: ::c_short) -> ::c_int;
    pub fn posix_spawnattr_getpgroup(
        attr: *const posix_spawnattr_t,
        flags: *mut ::pid_t,
    ) -> ::c_int;
    pub fn posix_spawnattr_setpgroup(attr: *mut posix_spawnattr_t, flags: ::pid_t) -> ::c_int;
    pub fn posix_spawnattr_getschedpolicy(
        attr: *const posix_spawnattr_t,
        flags: *mut ::c_int,
    ) -> ::c_int;
    pub fn posix_spawnattr_setschedpolicy(attr: *mut posix_spawnattr_t, flags: ::c_int) -> ::c_int;
    pub fn posix_spawnattr_getschedparam(
        attr: *const posix_spawnattr_t,
        param: *mut ::sched_param,
    ) -> ::c_int;
    pub fn posix_spawnattr_setschedparam(
        attr: *mut posix_spawnattr_t,
        param: *const ::sched_param,
    ) -> ::c_int;

    pub fn posix_spawn_file_actions_init(actions: *mut posix_spawn_file_actions_t) -> ::c_int;
    pub fn posix_spawn_file_actions_destroy(actions: *mut posix_spawn_file_actions_t) -> ::c_int;
    pub fn posix_spawn_file_actions_addopen(
        actions: *mut posix_spawn_file_actions_t,
        fd: ::c_int,
        path: *const ::c_char,
        oflag: ::c_int,
        mode: ::mode_t,
    ) -> ::c_int;
    pub fn posix_spawn_file_actions_addclose(
        actions: *mut posix_spawn_file_actions_t,
        fd: ::c_int,
    ) -> ::c_int;
    pub fn posix_spawn_file_actions_adddup2(
        actions: *mut posix_spawn_file_actions_t,
        fd: ::c_int,
        newfd: ::c_int,
    ) -> ::c_int;

    pub fn wait(status: *mut ::c_int) -> ::pid_t;
    pub fn waitpid(pid: ::pid_t, status: *mut ::c_int, options: ::c_int) -> ::pid_t;
    pub fn kill(pid: ::pid_t, sig: ::c_int) -> ::c_int;

    pub fn sigemptyset(set: *mut sigset_t) -> ::c_int;
    pub fn sigaddset(set: *mut sigset_t, signum: ::c_int) -> ::c_int;
    pub fn sigfillset(set: *mut sigset_t) -> ::c_int;
    pub fn sigdelset(set: *mut sigset_t, signum: ::c_int) -> ::c_int;
    pub fn sigismember(set: *const sigset_t, signum: ::c_int) -> ::c_int;

    pub fn sigprocmask(how: ::c_int, set: *const sigset_t, oldset: *mut sigset_t) -> ::c_int;
    pub fn sigpending(set: *mut sigset_t) -> ::c_int;

    pub fn pthread_self() -> ::pthread_t;
    pub fn pthread_join(native: ::pthread_t, value: *mut *mut ::c_void) -> ::c_int;
    pub fn pthread_exit(value: *mut ::c_void) -> !;
    pub fn pthread_attr_init(attr: *mut ::pthread_attr_t) -> ::c_int;
    pub fn pthread_attr_destroy(attr: *mut ::pthread_attr_t) -> ::c_int;
    pub fn pthread_attr_setstacksize(attr: *mut ::pthread_attr_t, stack_size: ::size_t) -> ::c_int;
    pub fn pthread_attr_setdetachstate(attr: *mut ::pthread_attr_t, state: ::c_int) -> ::c_int;
    pub fn pthread_detach(thread: ::pthread_t) -> ::c_int;
    pub fn pthread_create(
        native: *mut ::pthread_t,
        attr: *const ::pthread_attr_t,
        f: extern "C" fn(*mut ::c_void) -> *mut ::c_void,
        value: *mut ::c_void,
    ) -> ::c_int;
    pub fn pthread_key_create(
        key: *mut pthread_key_t,
        dtor: ::Option<unsafe extern "C" fn(*mut ::c_void)>,
    ) -> ::c_int;
    pub fn pthread_key_delete(key: pthread_key_t) -> ::c_int;
    pub fn pthread_getspecific(key: pthread_key_t) -> *mut ::c_void;
    pub fn pthread_setspecific(key: pthread_key_t, value: *const ::c_void) -> ::c_int;
    pub fn raise(signum: ::c_int) -> ::c_int;

    fn sigaction_external_default(
        sig: ::c_int,
        sa: *const sigaction,
        old: *mut sigaction,
        _external_handler: ::Option<unsafe extern "C" fn(::c_int)>,
    ) -> ::c_int;
    fn __wasm_signal(signum: ::c_int);
}

pub unsafe fn sigaction(sig: ::c_int, sa: *const sigaction, old: *mut sigaction) -> ::c_int {
    sigaction_external_default(sig, sa, old, ::Option::Some(default_handler))
}

extern "C" fn default_handler(sig: ::c_int) {
    if sig == SIGCHLD || sig == SIGURG || sig == SIGWINCH || sig == SIGCONT {
        return;
    } else {
        unsafe { ::abort() };
    }
}

/// mocked functions that dont do anything in WASI land
pub fn mlock(_addr: *const ::c_void, _len: ::size_t) -> ::c_int {
    0
}
pub fn munlock(_addr: *const ::c_void, _len: ::size_t) -> ::c_int {
    0
}
pub fn mlockall(_flags: ::c_int) -> ::c_int {
    0
}
pub fn munlockall() -> ::c_int {
    0
}

pub fn WIFSTOPPED(status: ::c_int) -> bool {
    (status & 0xff) == 0x7f
}

pub fn WSTOPSIG(status: ::c_int) -> ::c_int {
    (status >> 8) & 0xff
}

pub fn WIFCONTINUED(status: ::c_int) -> bool {
    status == 0xffff
}

pub fn WIFSIGNALED(status: ::c_int) -> bool {
    ((status & 0x7f) + 1) as i8 >= 2
}

pub fn WTERMSIG(status: ::c_int) -> ::c_int {
    status & 0x7f
}

pub fn WIFEXITED(status: ::c_int) -> bool {
    (status & 0x7f) == 0
}

pub fn WEXITSTATUS(status: ::c_int) -> ::c_int {
    (status >> 8) & 0xff
}

pub fn WCOREDUMP(status: ::c_int) -> bool {
    (status & 0x80) != 0
}

pub fn W_EXITCODE(ret: ::c_int, sig: ::c_int) -> ::c_int {
    (ret << 8) | sig
}

pub fn W_STOPCODE(sig: ::c_int) -> ::c_int {
    (sig << 8) | 0x7f
}

pub fn QCMD(cmd: ::c_int, type_: ::c_int) -> ::c_int {
    (cmd << 8) | (type_ & 0x00ff)
}
