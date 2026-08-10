pub type sighandler_t = crate::size_t;
pub type pthread_t = crate::c_ulong;
pub type pthread_key_t = crate::c_uint;
pub type socklen_t = u32;
pub type in_addr_t = u32;
pub type in_port_t = u16;
pub type sa_family_t = u16;
pub type sa_type_t = u16;

s! {
    #[repr(C)]
    pub struct in_addr {
        pub s_addr: crate::in_addr_t,
    }

    #[repr(C)]
    #[repr(align(4))]
    pub struct in6_addr {
        pub s6_addr: [u8; 16],
    }

    #[repr(C)]
    pub struct sockaddr_un {
        pub sun_family: sa_family_t,
        pub sun_path: [crate::c_char; 108],
    }

    #[repr(C)]
    pub struct sockaddr {
        pub sa_family: sa_family_t,
        pub sa_data: [crate::c_char; 14],
    }

    #[repr(C)]
    pub struct sockaddr_in {
        pub sin_family: sa_family_t,
        pub sin_port: crate::in_port_t,
        pub sin_addr: crate::in_addr,
        pub sin_zero: [u8; 8],
    }

    #[repr(C)]
    pub struct sockaddr_in6 {
        pub sin6_family: sa_family_t,
        pub sin6_port: crate::in_port_t,
        pub sin6_flowinfo: u32,
        pub sin6_addr: crate::in6_addr,
        pub sin6_scope_id: u32,
    }

    #[repr(C)]
    pub struct addrinfo {
        pub ai_flags: crate::c_int,
        pub ai_family: crate::c_int,
        pub ai_socktype: crate::c_int,
        pub ai_protocol: crate::c_int,
        pub ai_addrlen: socklen_t,
        pub ai_addr: *mut crate::sockaddr,
        pub ai_canonname: *mut crate::c_char,
        pub ai_next: *mut crate::addrinfo,
    }

    #[repr(C)]
    pub struct sockaddr_ll {
        pub sll_family: crate::c_ushort,
        pub sll_protocol: crate::c_ushort,
        pub sll_ifindex: crate::c_int,
        pub sll_hatype: crate::c_ushort,
        pub sll_pkttype: crate::c_uchar,
        pub sll_halen: crate::c_uchar,
        pub sll_addr: [crate::c_uchar; 8]
    }

    #[repr(C)]
    pub struct sockaddr_storage {
        pub ss_family: sa_family_t,
        __ss_align: crate::size_t,
        #[cfg(target_pointer_width = "32")]
        __ss_pad2: [u8; 128 - 2 * 4],
        #[cfg(target_pointer_width = "64")]
        __ss_pad2: [u8; 128 - 2 * 8],
    }

    #[repr(C)]
    #[repr(align(4))]
    pub struct ifaddrs {
        pub ifa_next: *mut ifaddrs,
        pub ifa_name: *mut crate::c_char,
        pub ifa_flags: crate::c_int,
        pub ifa_addr: *mut crate::sockaddr,
        pub ifa_netmask: *mut crate::sockaddr,
        pub ifu_broadaddr_or_dstaddr: *mut crate::sockaddr,
        pub ifa_data: *mut crate::c_uchar,
    }

    #[repr(C)]
    #[repr(align(4))]
    pub struct msghdr {
        pub msg_name: *mut crate::c_uchar,
        pub msg_namelen: crate::socklen_t,
        pub msg_iov: *mut crate::iovec,
        pub msg_iovlen: crate::size_t,
        pub msg_control: *mut crate::c_uchar,
        pub msg_controllen: crate::socklen_t,
        pub msg_flags: crate::c_int,
    }

    #[repr(C)]
    pub struct group_filter {
        pub gf_interface: u32,
        pub gf_group: crate::sockaddr_storage,
        pub gf_fmode: u32,
        pub gf_numsrc: u32,
        pub gf_slist: [crate::sockaddr_storage; 1],
    }

    #[repr(C)]
    pub struct group_req {
        pub gr_interface: u32,
        pub gr_group: crate::sockaddr_storage,
    }

    #[repr(C)]
    pub struct group_source_req {
        pub gsr_interface: u32,
        pub gsr_group: crate::sockaddr_storage,
        pub gsr_source: crate::sockaddr_storage,
    }

    #[repr(C)]
    pub struct in_pktinfo {
        pub ipi_ifindex: crate::c_int,
        pub ipi_spec_dst: crate::in_addr,
        pub ipi_addr: crate::in_addr,
    }

    #[repr(C)]
    pub struct ip6_mtuinfo {
        pub ip6m_addr: crate::sockaddr_in6,
        pub ip6m_mtu: u32,
    }

    #[repr(C)]
    pub struct in6_pktinfo {
        pub ipi6_addr: crate::in6_addr,
        pub ipi6_ifindex: crate::c_uint,
    }

    #[repr(C)]
    pub struct ip_mreq_source {
        pub imr_multiaddr: crate::in_addr,
        pub imr_interface: crate::in_addr,
        pub imr_sourceaddr: crate::in_addr,
    }

    #[repr(C)]
    pub struct ip_mreq {
        pub imr_multiaddr: crate::in_addr,
        pub imr_interface: crate::in_addr,
    }

    #[repr(C)]
    pub struct ip_mreqn {
        pub imr_multiaddr: crate::in_addr,
        pub imr_address: crate::in_addr,
        pub imr_ifindex: crate::c_int,
    }

    #[repr(C)]
    pub struct ip_msfilter {
        pub imsf_multiaddr: crate::in_addr,
        pub imsf_interface: crate::in_addr,
        pub imsf_fmode: u32,
        pub imsf_numsrc: u32,
        pub imsf_slist: [crate::in_addr; 1],
    }

    #[repr(C)]
    pub struct ip_opts {
        pub ip_dst: crate::in_addr,
        pub ip_opts: [crate::c_char; 40],
    }

    #[repr(C)]
    pub struct ipv6_mreq {
        pub ipv6mr_multiaddr: crate::in6_addr,
        pub ipv6mr_interface: crate::c_uint,
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
        pub len: crate::c_ushort,
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
        pub si_signo: crate::c_int,
        pub si_errno: crate::c_int,
        pub si_code: crate::c_int,
        _pad: [crate::c_int; 31],
        _align: [u64; 0],
    }

    #[repr(C)]
    pub struct sigaction {
        pub sa_sigaction: crate::sighandler_t,
        pub sa_mask: crate::sigset_t,
        pub sa_flags: crate::c_int,
        pub sa_restorer: Option<extern fn()>,
    }

    pub struct linger {
        pub l_onoff: crate::c_int,
        pub l_linger: crate::c_int,
    }

    pub struct sched_param {
        pub sched_priority: crate::c_int,
        pub sched_ss_low_priority: crate::c_int,
        pub sched_ss_repl_period: crate::timespec,
        pub sched_ss_init_budget: crate::timespec,
        pub sched_ss_max_repl: crate::c_int,
    }

    pub struct posix_spawn_file_actions_t {
        __allocated: crate::c_int,
        __used: crate::c_int,
        __actions: *mut crate::c_int,
        __pad: [crate::c_int; 16],
    }

    pub struct posix_spawnattr_t {
        __flags: crate::c_short,
        __pgrp: crate::pid_t,
        __sd: crate::sigset_t,
        __ss: crate::sigset_t,
        __prio: crate::c_int,
        __policy: crate::c_int,
        __pad: [crate::c_int; 16],
    }
}

pub const PTHREAD_STACK_MIN: crate::size_t = 2048;

pub const __WASI_SDFLAGS_RD: crate::c_int = 1;
pub const __WASI_SDFLAGS_WR: crate::c_int = 2;

pub const SHUT_RD: crate::c_int = __WASI_SDFLAGS_RD;
pub const SHUT_WR: crate::c_int = __WASI_SDFLAGS_WR;
pub const SHUT_RDWR: crate::c_int = SHUT_RD | SHUT_WR;

pub const __WASI_RIFLAGS_RECV_PEEK: crate::c_int = 1;
pub const __WASI_RIFLAGS_RECV_WAITALL: crate::c_int = 2;
pub const __WASI_RIFLAGS_RECV_DATA_TRUNCATED: crate::c_int = 4;

pub const MSG_OOB: crate::c_int = 0x0001;
pub const MSG_PEEK: crate::c_int = 0x0002;
pub const MSG_DONTROUTE: crate::c_int = 0x0004;
pub const MSG_CTRUNC: crate::c_int = 0x0008;
pub const MSG_PROXY: crate::c_int = 0x0010;
pub const MSG_TRUNC: crate::c_int = 0x0020;
pub const MSG_DONTWAIT: crate::c_int = 0x0040;
pub const MSG_EOR: crate::c_int = 0x0080;
pub const MSG_WAITALL: crate::c_int = 0x0100;
pub const MSG_FIN: crate::c_int = 0x0200;
pub const MSG_SYN: crate::c_int = 0x0400;
pub const MSG_CONFIRM: crate::c_int = 0x0800;
pub const MSG_RST: crate::c_int = 0x1000;
pub const MSG_ERRQUEUE: crate::c_int = 0x2000;
pub const MSG_NOSIGNAL: crate::c_int = 0x4000;
pub const MSG_MORE: crate::c_int = 0x8000;
pub const MSG_WAITFORONE: crate::c_int = 0x10000;
pub const MSG_BATCH: crate::c_int = 0x40000;
pub const MSG_ZEROCOPY: crate::c_int = 0x4000000;
pub const MSG_FASTOPEN: crate::c_int = 0x20000000;
pub const MSG_CMSG_CLOEXEC: crate::c_int = 0x40000000;

pub const __WASI_FILETYPE_UNKNOWN: crate::c_int = 0;
pub const __WASI_FILETYPE_BLOCK_DEVICE: crate::c_int = 1;
pub const __WASI_FILETYPE_CHARACTER_DEVICE: crate::c_int = 2;
pub const __WASI_FILETYPE_DIRECTORY: crate::c_int = 3;
pub const __WASI_FILETYPE_REGULAR_FILE: crate::c_int = 4;
pub const __WASI_FILETYPE_SOCKET_DGRAM: crate::c_int = 5;
pub const __WASI_FILETYPE_SOCKET_STREAM: crate::c_int = 6;
pub const __WASI_FILETYPE_SYMBOLIC_LINK: crate::c_int = 7;
pub const __WASI_FILETYPE_SOCKET_RAW: crate::c_int = 8;
pub const __WASI_FILETYPE_SOCKET_SEQPACKET: crate::c_int = 9;

pub const __WASI_SOCK_TYPE_SOCKET_UNUSED: crate::c_int = 0;
pub const __WASI_SOCK_TYPE_SOCKET_STREAM: crate::c_int = 1;
pub const __WASI_SOCK_TYPE_SOCKET_DGRAM: crate::c_int = 2;
pub const __WASI_SOCK_TYPE_SOCKET_RAW: crate::c_int = 3;
pub const __WASI_SOCK_TYPE_SOCKET_SEQPACKET: crate::c_int = 4;

pub const SOCK_DGRAM: crate::c_int = __WASI_SOCK_TYPE_SOCKET_DGRAM;
pub const SOCK_STREAM: crate::c_int = __WASI_SOCK_TYPE_SOCKET_STREAM;
pub const SOCK_RAW: crate::c_int = __WASI_SOCK_TYPE_SOCKET_RAW;
pub const SOCK_SEQPACKET: crate::c_int = __WASI_SOCK_TYPE_SOCKET_SEQPACKET;

pub const SOCK_NONBLOCK: crate::c_int = 0x00004000;
pub const SOCK_CLOEXEC: crate::c_int = 0x00002000;

pub const SOL_SOCKET: crate::c_int = 0x7fffffff;
pub const SOL_IP: crate::c_int = IPPROTO_IP;
pub const SOL_ICMP: crate::c_int = IPPROTO_ICMP;
pub const SOL_IGMP: crate::c_int = IPPROTO_IGMP;
pub const SOL_IPIP: crate::c_int = IPPROTO_IPIP;
pub const SOL_TCP: crate::c_int = IPPROTO_TCP;
pub const SOL_EGP: crate::c_int = IPPROTO_EGP;
pub const SOL_PUP: crate::c_int = IPPROTO_PUP;
pub const SOL_UDP: crate::c_int = IPPROTO_UDP;
pub const SOL_IDP: crate::c_int = IPPROTO_IDP;
pub const SOL_TP: crate::c_int = IPPROTO_TP;
pub const SOL_DCCP: crate::c_int = IPPROTO_DCCP;
pub const SOL_IPV6: crate::c_int = IPPROTO_IPV6;
pub const SOL_ROUTING: crate::c_int = IPPROTO_ROUTING;
pub const SOL_FRAGMENT: crate::c_int = IPPROTO_FRAGMENT;
pub const SOL_RSVP: crate::c_int = IPPROTO_RSVP;
pub const SOL_GRE: crate::c_int = IPPROTO_GRE;
pub const SOL_ESP: crate::c_int = IPPROTO_ESP;
pub const SOL_AH: crate::c_int = IPPROTO_AH;
pub const SOL_ICMPV6: crate::c_int = IPPROTO_ICMPV6;
pub const SOL_NONE: crate::c_int = IPPROTO_NONE;
pub const SOL_DSTOPTS: crate::c_int = IPPROTO_DSTOPTS;
pub const SOL_MTP: crate::c_int = IPPROTO_MTP;
pub const SOL_BEETPH: crate::c_int = IPPROTO_BEETPH;
pub const SOL_ENCAP: crate::c_int = IPPROTO_ENCAP;
pub const SOL_PIM: crate::c_int = IPPROTO_PIM;
pub const SOL_COMP: crate::c_int = IPPROTO_COMP;
pub const SOL_SCTP: crate::c_int = IPPROTO_SCTP;
pub const SOL_MH: crate::c_int = IPPROTO_MH;
pub const SOL_UDPLITE: crate::c_int = IPPROTO_UDPLITE;
pub const SOL_MPLS: crate::c_int = IPPROTO_MPLS;
pub const SOL_ETHERNET: crate::c_int = IPPROTO_ETHERNET;
pub const SOL_MPTCP: crate::c_int = IPPROTO_MPTCP;

pub const __WASI_SOCK_OPTION_NOOP: crate::c_int = 0;
pub const __WASI_SOCK_OPTION_REUSE_PORT: crate::c_int = 1;
pub const __WASI_SOCK_OPTION_REUSE_ADDR: crate::c_int = 2;
pub const __WASI_SOCK_OPTION_NO_DELAY: crate::c_int = 3;
pub const __WASI_SOCK_OPTION_DONT_ROUTE: crate::c_int = 4;
pub const __WASI_SOCK_OPTION_ONLY_V6: crate::c_int = 5;
pub const __WASI_SOCK_OPTION_BROADCAST: crate::c_int = 6;
pub const __WASI_SOCK_OPTION_MULTICAST_LOOP_V4: crate::c_int = 7;
pub const __WASI_SOCK_OPTION_MULTICAST_LOOP_V6: crate::c_int = 8;
pub const __WASI_SOCK_OPTION_PROMISCUOUS: crate::c_int = 9;
pub const __WASI_SOCK_OPTION_LISTENING: crate::c_int = 10;
pub const __WASI_SOCK_OPTION_LAST_ERROR: crate::c_int = 11;
pub const __WASI_SOCK_OPTION_KEEP_ALIVE: crate::c_int = 12;
pub const __WASI_SOCK_OPTION_LINGER: crate::c_int = 13;
pub const __WASI_SOCK_OPTION_OOB_INLINE: crate::c_int = 14;
pub const __WASI_SOCK_OPTION_RECV_BUF_SIZE: crate::c_int = 15;
pub const __WASI_SOCK_OPTION_SEND_BUF_SIZE: crate::c_int = 16;
pub const __WASI_SOCK_OPTION_RECV_LOWAT: crate::c_int = 17;
pub const __WASI_SOCK_OPTION_SEND_LOWAT: crate::c_int = 18;
pub const __WASI_SOCK_OPTION_RECV_TIMEOUT: crate::c_int = 19;
pub const __WASI_SOCK_OPTION_SEND_TIMEOUT: crate::c_int = 20;
pub const __WASI_SOCK_OPTION_CONNECT_TIMEOUT: crate::c_int = 21;
pub const __WASI_SOCK_OPTION_ACCEPT_TIMEOUT: crate::c_int = 22;
pub const __WASI_SOCK_OPTION_TTL: crate::c_int = 23;
pub const __WASI_SOCK_OPTION_MULTICAST_TTL_V4: crate::c_int = 24;
pub const __WASI_SOCK_OPTION_TYPE: crate::c_int = 25;
pub const __WASI_SOCK_OPTION_PROTO: crate::c_int = 26;

pub const SO_ACCEPTCONN: crate::c_int = __WASI_SOCK_OPTION_LISTENING;
pub const SO_BROADCAST: crate::c_int = __WASI_SOCK_OPTION_BROADCAST;
pub const SO_DONTROUTE: crate::c_int = __WASI_SOCK_OPTION_DONT_ROUTE;
pub const SO_NODELAY: crate::c_int = __WASI_SOCK_OPTION_NO_DELAY;
pub const SO_ERROR: crate::c_int = __WASI_SOCK_OPTION_LAST_ERROR;
pub const SO_KEEPALIVE: crate::c_int = __WASI_SOCK_OPTION_KEEP_ALIVE;
pub const SO_LINGER: crate::c_int = __WASI_SOCK_OPTION_LINGER;
pub const SO_OOBINLINE: crate::c_int = __WASI_SOCK_OPTION_OOB_INLINE;
pub const SO_ONLYV6: crate::c_int = __WASI_SOCK_OPTION_ONLY_V6;
pub const SO_RCVBUF: crate::c_int = __WASI_SOCK_OPTION_RECV_BUF_SIZE;
pub const SO_RCVLOWAT: crate::c_int = __WASI_SOCK_OPTION_RECV_LOWAT;
pub const SO_RCVTIMEO: crate::c_int = __WASI_SOCK_OPTION_RECV_TIMEOUT;
pub const SO_REUSEPORT: crate::c_int = __WASI_SOCK_OPTION_REUSE_PORT;
pub const SO_REUSEADDR: crate::c_int = __WASI_SOCK_OPTION_REUSE_ADDR;
pub const SO_SNDBUF: crate::c_int = __WASI_SOCK_OPTION_SEND_BUF_SIZE;
pub const SO_SNDLOWAT: crate::c_int = __WASI_SOCK_OPTION_SEND_LOWAT;
pub const SO_SNDTIMEO: crate::c_int = __WASI_SOCK_OPTION_SEND_TIMEOUT;
pub const SO_MCASTLOOPV4: crate::c_int = __WASI_SOCK_OPTION_MULTICAST_LOOP_V4;
pub const SO_MCASTLOOPV6: crate::c_int = __WASI_SOCK_OPTION_MULTICAST_LOOP_V6;
pub const SO_CONNTIMEO: crate::c_int = __WASI_SOCK_OPTION_CONNECT_TIMEOUT;
pub const SO_ACCPTIMEO: crate::c_int = __WASI_SOCK_OPTION_ACCEPT_TIMEOUT;
pub const SO_TTL: crate::c_int = __WASI_SOCK_OPTION_TTL;
pub const SO_MCASTTTLV4: crate::c_int = __WASI_SOCK_OPTION_MULTICAST_TTL_V4;
pub const SO_TYPE: crate::c_int = __WASI_SOCK_OPTION_TYPE;
pub const SO_PROTOCOL: crate::c_int = __WASI_SOCK_OPTION_PROTO;
pub const SO_MARK: crate::c_int = __WASI_SOCK_OPTION_NOOP;
pub const SO_BINDTODEVICE: crate::c_int = __WASI_SOCK_OPTION_NOOP;
pub const SO_INCOMING_CPU: crate::c_int = __WASI_SOCK_OPTION_NOOP;
pub const SO_ATTACH_FILTER: crate::c_int = __WASI_SOCK_OPTION_NOOP;
pub const SO_DETACH_FILTER: crate::c_int = __WASI_SOCK_OPTION_NOOP;

pub const AF_UNSPEC: crate::c_int = 0;
pub const AF_INET: crate::c_int = 1;
pub const AF_INET6: crate::c_int = 2;
pub const AF_UNIX: crate::c_int = 3;

pub const IF_NAMESIZE: crate::size_t = 16;
pub const IFNAMSIZ: crate::size_t = IF_NAMESIZE;

pub const IPPROTO_IP: crate::c_int = 0;
pub const IPPROTO_HOPOPTS: crate::c_int = 0;
pub const IPPROTO_ICMP: crate::c_int = 1;
pub const IPPROTO_IGMP: crate::c_int = 2;
pub const IPPROTO_IPIP: crate::c_int = 4;
pub const IPPROTO_TCP: crate::c_int = 6;
pub const IPPROTO_EGP: crate::c_int = 8;
pub const IPPROTO_PUP: crate::c_int = 12;
pub const IPPROTO_UDP: crate::c_int = 17;
pub const IPPROTO_IDP: crate::c_int = 22;
pub const IPPROTO_TP: crate::c_int = 29;
pub const IPPROTO_DCCP: crate::c_int = 33;
pub const IPPROTO_IPV6: crate::c_int = 41;
pub const IPPROTO_ROUTING: crate::c_int = 43;
pub const IPPROTO_FRAGMENT: crate::c_int = 44;
pub const IPPROTO_RSVP: crate::c_int = 46;
pub const IPPROTO_GRE: crate::c_int = 47;
pub const IPPROTO_ESP: crate::c_int = 50;
pub const IPPROTO_AH: crate::c_int = 51;
pub const IPPROTO_ICMPV6: crate::c_int = 58;
pub const IPPROTO_NONE: crate::c_int = 59;
pub const IPPROTO_DSTOPTS: crate::c_int = 60;
pub const IPPROTO_MTP: crate::c_int = 92;
pub const IPPROTO_BEETPH: crate::c_int = 94;
pub const IPPROTO_ENCAP: crate::c_int = 98;
pub const IPPROTO_PIM: crate::c_int = 103;
pub const IPPROTO_COMP: crate::c_int = 108;
pub const IPPROTO_SCTP: crate::c_int = 132;
pub const IPPROTO_MH: crate::c_int = 135;
pub const IPPROTO_UDPLITE: crate::c_int = 136;
pub const IPPROTO_MPLS: crate::c_int = 137;
pub const IPPROTO_ETHERNET: crate::c_int = 143;
pub const IPPROTO_RAW: crate::c_int = 255;
pub const IPPROTO_MPTCP: crate::c_int = 262;
pub const IPPROTO_MAX: crate::c_int = 263;

pub const IP_TOS: crate::c_int = 1;
pub const IP_TTL: crate::c_int = 2;
pub const IP_HDRINCL: crate::c_int = 3;
pub const IP_OPTIONS: crate::c_int = 4;
pub const IP_ROUTER_ALERT: crate::c_int = 5;
pub const IP_RECVOPTS: crate::c_int = 6;
pub const IP_RETOPTS: crate::c_int = 7;
pub const IP_PKTINFO: crate::c_int = 8;
pub const IP_PKTOPTIONS: crate::c_int = 9;
pub const IP_PMTUDISC: crate::c_int = 10;
pub const IP_MTU_DISCOVER: crate::c_int = 10;
pub const IP_RECVERR: crate::c_int = 11;
pub const IP_RECVTTL: crate::c_int = 12;
pub const IP_RECVTOS: crate::c_int = 13;
pub const IP_MTU: crate::c_int = 14;
pub const IP_FREEBIND: crate::c_int = 15;
pub const IP_IPSEC_POLICY: crate::c_int = 16;
pub const IP_XFRM_POLICY: crate::c_int = 17;
pub const IP_PASSSEC: crate::c_int = 18;
pub const IP_TRANSPARENT: crate::c_int = 19;
pub const IP_ORIGDSTADDR: crate::c_int = 20;
pub const IP_RECVORIGDSTADDR: crate::c_int = IP_ORIGDSTADDR;
pub const IP_MINTTL: crate::c_int = 21;
pub const IP_NODEFRAG: crate::c_int = 22;
pub const IP_CHECKSUM: crate::c_int = 23;
pub const IP_BIND_ADDRESS_NO_PORT: crate::c_int = 24;
pub const IP_RECVFRAGSIZE: crate::c_int = 25;
pub const IP_RECVERR_RFC4884: crate::c_int = 26;
pub const IP_MULTICAST_IF: crate::c_int = 32;
pub const IP_MULTICAST_TTL: crate::c_int = 33;
pub const IP_MULTICAST_LOOP: crate::c_int = 34;
pub const IP_ADD_MEMBERSHIP: crate::c_int = 35;
pub const IP_DROP_MEMBERSHIP: crate::c_int = 36;
pub const IP_UNBLOCK_SOURCE: crate::c_int = 37;
pub const IP_BLOCK_SOURCE: crate::c_int = 38;
pub const IP_ADD_SOURCE_MEMBERSHIP: crate::c_int = 39;
pub const IP_DROP_SOURCE_MEMBERSHIP: crate::c_int = 40;
pub const IP_MSFILTER: crate::c_int = 41;
pub const IP_MULTICAST_ALL: crate::c_int = 49;
pub const IP_UNICAST_IF: crate::c_int = 50;

pub const IP_RECVRETOPTS: crate::c_int = IP_RETOPTS;

pub const IP_PMTUDISC_DONT: crate::c_int = 0;
pub const IP_PMTUDISC_WANT: crate::c_int = 1;
pub const IP_PMTUDISC_DO: crate::c_int = 2;
pub const IP_PMTUDISC_PROBE: crate::c_int = 3;
pub const IP_PMTUDISC_INTERFACE: crate::c_int = 4;
pub const IP_PMTUDISC_OMIT: crate::c_int = 5;

pub const IP_DEFAULT_MULTICAST_TTL: crate::c_int = 1;
pub const IP_DEFAULT_MULTICAST_LOOP: crate::c_int = 1;
pub const IP_MAX_MEMBERSHIPS: crate::c_int = 20;

pub const MCAST_JOIN_GROUP: crate::c_int = 42;
pub const MCAST_BLOCK_SOURCE: crate::c_int = 43;
pub const MCAST_UNBLOCK_SOURCE: crate::c_int = 44;
pub const MCAST_LEAVE_GROUP: crate::c_int = 45;
pub const MCAST_JOIN_SOURCE_GROUP: crate::c_int = 46;
pub const MCAST_LEAVE_SOURCE_GROUP: crate::c_int = 47;
pub const MCAST_MSFILTER: crate::c_int = 48;

pub const MCAST_EXCLUDE: crate::c_int = 0;
pub const MCAST_INCLUDE: crate::c_int = 1;

pub const IPV6_ADDRFORM: crate::c_int = 1;
pub const IPV6_2292PKTINFO: crate::c_int = 2;
pub const IPV6_2292HOPOPTS: crate::c_int = 3;
pub const IPV6_2292DSTOPTS: crate::c_int = 4;
pub const IPV6_2292RTHDR: crate::c_int = 5;
pub const IPV6_2292PKTOPTIONS: crate::c_int = 6;
pub const IPV6_CHECKSUM: crate::c_int = 7;
pub const IPV6_2292HOPLIMIT: crate::c_int = 8;
pub const IPV6_NEXTHOP: crate::c_int = 9;
pub const IPV6_AUTHHDR: crate::c_int = 10;
pub const IPV6_UNICAST_HOPS: crate::c_int = 16;
pub const IPV6_MULTICAST_IF: crate::c_int = 17;
pub const IPV6_MULTICAST_HOPS: crate::c_int = 18;
pub const IPV6_MULTICAST_LOOP: crate::c_int = 19;
pub const IPV6_JOIN_GROUP: crate::c_int = 20;
pub const IPV6_LEAVE_GROUP: crate::c_int = 21;
pub const IPV6_ROUTER_ALERT: crate::c_int = 22;
pub const IPV6_MTU_DISCOVER: crate::c_int = 23;
pub const IPV6_MTU: crate::c_int = 24;
pub const IPV6_RECVERR: crate::c_int = 25;
pub const IPV6_V6ONLY: crate::c_int = 26;
pub const IPV6_JOIN_ANYCAST: crate::c_int = 27;
pub const IPV6_LEAVE_ANYCAST: crate::c_int = 28;
pub const IPV6_MULTICAST_ALL: crate::c_int = 29;
pub const IPV6_ROUTER_ALERT_ISOLATE: crate::c_int = 30;
pub const IPV6_IPSEC_POLICY: crate::c_int = 34;
pub const IPV6_XFRM_POLICY: crate::c_int = 35;
pub const IPV6_HDRINCL: crate::c_int = 36;

pub const IPV6_RECVPKTINFO: crate::c_int = 49;
pub const IPV6_PKTINFO: crate::c_int = 50;
pub const IPV6_RECVHOPLIMIT: crate::c_int = 51;
pub const IPV6_HOPLIMIT: crate::c_int = 52;
pub const IPV6_RECVHOPOPTS: crate::c_int = 53;
pub const IPV6_HOPOPTS: crate::c_int = 54;
pub const IPV6_RTHDRDSTOPTS: crate::c_int = 55;
pub const IPV6_RECVRTHDR: crate::c_int = 56;
pub const IPV6_RTHDR: crate::c_int = 57;
pub const IPV6_RECVDSTOPTS: crate::c_int = 58;
pub const IPV6_DSTOPTS: crate::c_int = 59;
pub const IPV6_RECVPATHMTU: crate::c_int = 60;
pub const IPV6_PATHMTU: crate::c_int = 61;
pub const IPV6_DONTFRAG: crate::c_int = 62;
pub const IPV6_RECVTCLASS: crate::c_int = 66;
pub const IPV6_TCLASS: crate::c_int = 67;
pub const IPV6_AUTOFLOWLABEL: crate::c_int = 70;
pub const IPV6_ADDR_PREFERENCES: crate::c_int = 72;
pub const IPV6_MINHOPCOUNT: crate::c_int = 73;
pub const IPV6_ORIGDSTADDR: crate::c_int = 74;
pub const IPV6_RECVORIGDSTADDR: crate::c_int = IPV6_ORIGDSTADDR;
pub const IPV6_TRANSPARENT: crate::c_int = 75;
pub const IPV6_UNICAST_IF: crate::c_int = 76;
pub const IPV6_RECVFRAGSIZE: crate::c_int = 77;
pub const IPV6_FREEBIND: crate::c_int = 78;

pub const IPV6_ADD_MEMBERSHIP: crate::c_int = IPV6_JOIN_GROUP;
pub const IPV6_DROP_MEMBERSHIP: crate::c_int = IPV6_LEAVE_GROUP;
pub const IPV6_RXHOPOPTS: crate::c_int = IPV6_HOPOPTS;
pub const IPV6_RXDSTOPTS: crate::c_int = IPV6_DSTOPTS;

pub const IPV6_PMTUDISC_DONT: crate::c_int = 0;
pub const IPV6_PMTUDISC_WANT: crate::c_int = 1;
pub const IPV6_PMTUDISC_DO: crate::c_int = 2;
pub const IPV6_PMTUDISC_PROBE: crate::c_int = 3;
pub const IPV6_PMTUDISC_INTERFACE: crate::c_int = 4;
pub const IPV6_PMTUDISC_OMIT: crate::c_int = 5;

pub const IPV6_PREFER_SRC_TMP: crate::c_int = 0x0001;
pub const IPV6_PREFER_SRC_PUBLIC: crate::c_int = 0x0002;
pub const IPV6_PREFER_SRC_PUBTMP_DEFAULT: crate::c_int = 0x0100;
pub const IPV6_PREFER_SRC_COA: crate::c_int = 0x0004;
pub const IPV6_PREFER_SRC_HOME: crate::c_int = 0x0400;
pub const IPV6_PREFER_SRC_CGA: crate::c_int = 0x0008;
pub const IPV6_PREFER_SRC_NONCGA: crate::c_int = 0x0800;

pub const IPV6_RTHDR_LOOSE: crate::c_int = 0;
pub const IPV6_RTHDR_STRICT: crate::c_int = 1;

pub const IPV6_RTHDR_TYPE_0: crate::c_int = 0;

pub const TCP_NODELAY: crate::c_int = 1;
pub const TCP_MAXSEG: crate::c_int = 2;
pub const TCP_CORK: crate::c_int = 3;
pub const TCP_KEEPIDLE: crate::c_int = 4;
pub const TCP_KEEPINTVL: crate::c_int = 5;
pub const TCP_KEEPCNT: crate::c_int = 6;
pub const TCP_SYNCNT: crate::c_int = 7;
pub const TCP_LINGER2: crate::c_int = 8;
pub const TCP_DEFER_ACCEPT: crate::c_int = 9;
pub const TCP_WINDOW_CLAMP: crate::c_int = 10;
pub const TCP_INFO: crate::c_int = 11;
pub const TCP_QUICKACK: crate::c_int = 12;
pub const TCP_CONGESTION: crate::c_int = 13;
pub const TCP_MD5SIG: crate::c_int = 14;
pub const TCP_THIN_LINEAR_TIMEOUTS: crate::c_int = 16;
pub const TCP_THIN_DUPACK: crate::c_int = 17;
pub const TCP_USER_TIMEOUT: crate::c_int = 18;
pub const TCP_REPAIR: crate::c_int = 19;
pub const TCP_REPAIR_QUEUE: crate::c_int = 20;
pub const TCP_QUEUE_SEQ: crate::c_int = 21;
pub const TCP_REPAIR_OPTIONS: crate::c_int = 22;
pub const TCP_FASTOPEN: crate::c_int = 23;
pub const TCP_TIMESTAMP: crate::c_int = 24;
pub const TCP_NOTSENT_LOWAT: crate::c_int = 25;
pub const TCP_CC_INFO: crate::c_int = 26;
pub const TCP_SAVE_SYN: crate::c_int = 27;
pub const TCP_SAVED_SYN: crate::c_int = 28;
pub const TCP_REPAIR_WINDOW: crate::c_int = 29;
pub const TCP_FASTOPEN_CONNECT: crate::c_int = 30;
pub const TCP_ULP: crate::c_int = 31;
pub const TCP_MD5SIG_EXT: crate::c_int = 32;
pub const TCP_FASTOPEN_KEY: crate::c_int = 33;
pub const TCP_FASTOPEN_NO_COOKIE: crate::c_int = 34;
pub const TCP_ZEROCOPY_RECEIVE: crate::c_int = 35;
pub const TCP_INQ: crate::c_int = 36;
pub const TCP_TX_DELAY: crate::c_int = 37;

pub const TCP_CM_INQ: crate::c_int = TCP_INQ;

pub const TCP_ESTABLISHED: crate::c_int = 1;
pub const TCP_SYN_SENT: crate::c_int = 2;
pub const TCP_SYN_RECV: crate::c_int = 3;
pub const TCP_FIN_WAIT1: crate::c_int = 4;
pub const TCP_FIN_WAIT2: crate::c_int = 5;
pub const TCP_TIME_WAIT: crate::c_int = 6;
pub const TCP_CLOSE: crate::c_int = 7;
pub const TCP_CLOSE_WAIT: crate::c_int = 8;
pub const TCP_LAST_ACK: crate::c_int = 9;
pub const TCP_LISTEN: crate::c_int = 10;
pub const TCP_CLOSING: crate::c_int = 11;

pub const PRIO_MIN: crate::c_int = -20;
pub const PRIO_MAX: crate::c_int = 20;

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

pub const POSIX_SPAWN_RESETIDS: crate::c_int = 0x01;
pub const POSIX_SPAWN_SETPGROUP: crate::c_int = 0x02;
pub const POSIX_SPAWN_SETSIGDEF: crate::c_int = 0x04;
pub const POSIX_SPAWN_SETSIGMASK: crate::c_int = 0x08;
pub const POSIX_SPAWN_SETSCHEDPARAM: crate::c_int = 0x10;
pub const POSIX_SPAWN_SETSCHEDULER: crate::c_int = 0x20;

pub const WNOHANG: crate::c_int = 0x00000001;
pub const WUNTRACED: crate::c_int = 0x00000002;
pub const WSTOPPED: crate::c_int = WUNTRACED;
pub const WEXITED: crate::c_int = 0x00000004;
pub const WCONTINUED: crate::c_int = 0x00000008;
pub const WNOWAIT: crate::c_int = 0x01000000;

pub const SIG_DFL: sighandler_t = 0 as sighandler_t;
pub const SIG_IGN: sighandler_t = 1 as sighandler_t;
pub const SIG_ERR: sighandler_t = !0 as sighandler_t;

pub const SIGHUP: crate::c_int = 1;
pub const SIGINT: crate::c_int = 2;
pub const SIGQUIT: crate::c_int = 3;
pub const SIGILL: crate::c_int = 4;
pub const SIGTRAP: crate::c_int = 5;
pub const SIGABRT: crate::c_int = 6;
pub const SIGBUS: crate::c_int = 7;
pub const SIGFPE: crate::c_int = 8;
pub const SIGKILL: crate::c_int = 9;
pub const SIGUSR1: crate::c_int = 10;
pub const SIGSEGV: crate::c_int = 11;
pub const SIGUSR2: crate::c_int = 12;
pub const SIGPIPE: crate::c_int = 13;
pub const SIGALRM: crate::c_int = 14;
pub const SIGTERM: crate::c_int = 15;
pub const SIGSTKFLT: crate::c_int = 16;
pub const SIGCHLD: crate::c_int = 17;
pub const SIGCONT: crate::c_int = 18;
pub const SIGSTOP: crate::c_int = 19;
pub const SIGTSTP: crate::c_int = 20;
pub const SIGTTIN: crate::c_int = 21;
pub const SIGTTOU: crate::c_int = 22;
pub const SIGURG: crate::c_int = 23;
pub const SIGXCPU: crate::c_int = 24;
pub const SIGXFSZ: crate::c_int = 25;
pub const SIGVTALRM: crate::c_int = 26;
pub const SIGPROF: crate::c_int = 27;
pub const SIGWINCH: crate::c_int = 28;
pub const SIGIO: crate::c_int = 29;
pub const SIGPOLL: crate::c_int = 29;
pub const SIGPWR: crate::c_int = 30;
pub const SIGSYS: crate::c_int = 31;

pub const SIG_BLOCK: crate::c_int = 0;
pub const SIG_UNBLOCK: crate::c_int = 1;
pub const SIG_SETMASK: crate::c_int = 2;

pub const SA_NOCLDSTOP: crate::c_int = 1;
pub const SA_NOCLDWAIT: crate::c_int = 2;
pub const SA_SIGINFO: crate::c_int = 4;
pub const SA_ONSTACK: crate::c_int = 0x08000000;
pub const SA_RESTART: crate::c_int = 0x10000000;
pub const SA_NODEFER: crate::c_int = 0x40000000;
pub const SA_RESETHAND: crate::c_int = 0x80000000;
pub const SA_RESTORER: crate::c_int = 0x04000000;

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
    pub fn dup(fd: crate::c_int) -> crate::c_int;
    pub fn dup2(src: crate::c_int, dst: crate::c_int) -> crate::c_int;

    pub fn accept(socket: crate::c_int, addr: *mut sockaddr, addrlen: *mut socklen_t) -> crate::c_int;
    pub fn accept4(
        socket: crate::c_int,
        addr: *mut sockaddr,
        addrlen: *mut socklen_t,
        flags: crate::c_int,
    ) -> crate::c_int;
    pub fn bind(socket: crate::c_int, addr: *const crate::sockaddr, addrlen: crate::socklen_t) -> crate::c_int;
    pub fn connect(socket: crate::c_int, addr: *const sockaddr, addrlen: socklen_t) -> crate::c_int;
    pub fn freeifaddrs(ifa: *mut crate::ifaddrs);
    pub fn getifaddrs(ifap: *mut *mut crate::ifaddrs) -> crate::c_int;
    pub fn getpeername(socket: crate::c_int, addr: *mut sockaddr, addrlen: *mut socklen_t) -> crate::c_int;
    pub fn getsockname(socket: crate::c_int, addr: *mut sockaddr, addrlen: *mut socklen_t) -> crate::c_int;
    pub fn getsockopt(
        sockfd: crate::c_int,
        level: crate::c_int,
        option_name: crate::c_int,
        option_value: *mut crate::c_void,
        option_len: *mut crate::socklen_t,
    ) -> crate::c_int;
    pub fn listen(socket: crate::c_int, backlog: crate::c_int) -> crate::c_int;
    pub fn recvfrom(
        socket: crate::c_int,
        buffer: *mut crate::c_void,
        length: crate::size_t,
        flags: crate::c_int,
        addr: *mut crate::sockaddr,
        addrlen: *mut crate::socklen_t,
    ) -> crate::ssize_t;
    pub fn recvmsg(socket: crate::c_int, msg: *mut crate::msghdr, flags: crate::c_int) -> crate::ssize_t;
    pub fn sendfile(
        socket: crate::c_int,
        in_fd: crate::c_int,
        ofs: *const crate::off_t,
        count: crate::size_t,
    ) -> crate::ssize_t;
    pub fn sendmsg(socket: crate::c_int, msg: *const crate::msghdr, flags: crate::c_int) -> crate::ssize_t;
    pub fn sendto(
        socket: crate::c_int,
        buffer: *const crate::c_void,
        length: crate::size_t,
        flags: crate::c_int,
        addr: *const sockaddr,
        addrlen: socklen_t,
    ) -> crate::ssize_t;
    pub fn setsockopt(
        socket: crate::c_int,
        level: crate::c_int,
        option_name: crate::c_int,
        option_value: *const crate::c_void,
        option_len: socklen_t,
    ) -> crate::c_int;
    pub fn socket(domain: crate::c_int, ty: crate::c_int, protocol: crate::c_int) -> crate::c_int;
    pub fn socketpair(
        domain: crate::c_int,
        ty: crate::c_int,
        protocol: crate::c_int,
        socket_vector: *mut crate::c_int,
    ) -> crate::c_int;

    pub fn __wasilibc_initialize_environ();
    pub fn __wasilibc_get_stack_pointer() -> *mut crate::c_void;
    pub fn __wasilibc_set_stack_pointer(val: *mut crate::c_void);
    pub fn __wasilibc_get_pthread_self() -> *mut crate::c_void;
    pub fn __wasilibc_set_pthread_self(val: *mut crate::c_void);
    pub fn __wasilibc_init_tls(val: *mut crate::c_void);
    pub fn __wasilibc_tls_size() -> u64;
    pub fn __wasilibc_tls_align() -> u64;
    pub fn __wasilibc_get_tls_base() -> *mut crate::c_void;
    pub fn __wasilibc_set_tls_base(val: *mut crate::c_void);

    pub fn getpid() -> crate::pid_t;

    pub fn execl(path: *const crate::c_char, arg0: *const crate::c_char, ...) -> crate::c_int;
    pub fn execle(path: *const crate::c_char, arg0: *const crate::c_char, ...) -> crate::c_int;
    pub fn execlp(file: *const crate::c_char, arg0: *const crate::c_char, ...) -> crate::c_int;
    pub fn execv(prog: *const crate::c_char, argv: *const *const crate::c_char) -> crate::c_int;
    pub fn execve(
        prog: *const crate::c_char,
        argv: *const *const crate::c_char,
        envp: *const *const crate::c_char,
    ) -> crate::c_int;
    pub fn execvp(c: *const crate::c_char, argv: *const *const crate::c_char) -> crate::c_int;
    pub fn fork() -> crate::pid_t;

    pub fn posix_spawn(
        pid: *mut crate::pid_t,
        path: *const crate::c_char,
        file_actions: *const crate::posix_spawn_file_actions_t,
        attrp: *const crate::posix_spawnattr_t,
        argv: *const *mut crate::c_char,
        envp: *const *mut crate::c_char,
    ) -> crate::c_int;
    pub fn posix_spawnp(
        pid: *mut crate::pid_t,
        file: *const crate::c_char,
        file_actions: *const crate::posix_spawn_file_actions_t,
        attrp: *const crate::posix_spawnattr_t,
        argv: *const *mut crate::c_char,
        envp: *const *mut crate::c_char,
    ) -> crate::c_int;
    pub fn posix_spawnattr_init(attr: *mut posix_spawnattr_t) -> crate::c_int;
    pub fn posix_spawnattr_destroy(attr: *mut posix_spawnattr_t) -> crate::c_int;
    pub fn posix_spawnattr_getsigdefault(
        attr: *const posix_spawnattr_t,
        default: *mut crate::sigset_t,
    ) -> crate::c_int;
    pub fn posix_spawnattr_setsigdefault(
        attr: *mut posix_spawnattr_t,
        default: *const crate::sigset_t,
    ) -> crate::c_int;
    pub fn posix_spawnattr_getsigmask(
        attr: *const posix_spawnattr_t,
        default: *mut crate::sigset_t,
    ) -> crate::c_int;
    pub fn posix_spawnattr_setsigmask(
        attr: *mut posix_spawnattr_t,
        default: *const crate::sigset_t,
    ) -> crate::c_int;
    pub fn posix_spawnattr_getflags(
        attr: *const posix_spawnattr_t,
        flags: *mut crate::c_short,
    ) -> crate::c_int;
    pub fn posix_spawnattr_setflags(attr: *mut posix_spawnattr_t, flags: crate::c_short) -> crate::c_int;
    pub fn posix_spawnattr_getpgroup(
        attr: *const posix_spawnattr_t,
        flags: *mut crate::pid_t,
    ) -> crate::c_int;
    pub fn posix_spawnattr_setpgroup(attr: *mut posix_spawnattr_t, flags: crate::pid_t) -> crate::c_int;
    pub fn posix_spawnattr_getschedpolicy(
        attr: *const posix_spawnattr_t,
        flags: *mut crate::c_int,
    ) -> crate::c_int;
    pub fn posix_spawnattr_setschedpolicy(attr: *mut posix_spawnattr_t, flags: crate::c_int) -> crate::c_int;
    pub fn posix_spawnattr_getschedparam(
        attr: *const posix_spawnattr_t,
        param: *mut crate::sched_param,
    ) -> crate::c_int;
    pub fn posix_spawnattr_setschedparam(
        attr: *mut posix_spawnattr_t,
        param: *const crate::sched_param,
    ) -> crate::c_int;

    pub fn posix_spawn_file_actions_init(actions: *mut posix_spawn_file_actions_t) -> crate::c_int;
    pub fn posix_spawn_file_actions_destroy(actions: *mut posix_spawn_file_actions_t) -> crate::c_int;
    pub fn posix_spawn_file_actions_addopen(
        actions: *mut posix_spawn_file_actions_t,
        fd: crate::c_int,
        path: *const crate::c_char,
        oflag: crate::c_int,
        mode: crate::mode_t,
    ) -> crate::c_int;
    pub fn posix_spawn_file_actions_addclose(
        actions: *mut posix_spawn_file_actions_t,
        fd: crate::c_int,
    ) -> crate::c_int;
    pub fn posix_spawn_file_actions_adddup2(
        actions: *mut posix_spawn_file_actions_t,
        fd: crate::c_int,
        newfd: crate::c_int,
    ) -> crate::c_int;

    pub fn wait(status: *mut crate::c_int) -> crate::pid_t;
    pub fn waitpid(pid: crate::pid_t, status: *mut crate::c_int, options: crate::c_int) -> crate::pid_t;
    pub fn kill(pid: crate::pid_t, sig: crate::c_int) -> crate::c_int;

    pub fn sigemptyset(set: *mut sigset_t) -> crate::c_int;
    pub fn sigaddset(set: *mut sigset_t, signum: crate::c_int) -> crate::c_int;
    pub fn sigfillset(set: *mut sigset_t) -> crate::c_int;
    pub fn sigdelset(set: *mut sigset_t, signum: crate::c_int) -> crate::c_int;
    pub fn sigismember(set: *const sigset_t, signum: crate::c_int) -> crate::c_int;

    pub fn sigprocmask(how: crate::c_int, set: *const sigset_t, oldset: *mut sigset_t) -> crate::c_int;
    pub fn sigpending(set: *mut sigset_t) -> crate::c_int;

    pub fn pthread_self() -> crate::pthread_t;
    pub fn pthread_join(native: crate::pthread_t, value: *mut *mut crate::c_void) -> crate::c_int;
    pub fn pthread_exit(value: *mut crate::c_void) -> !;
    pub fn pthread_attr_init(attr: *mut crate::pthread_attr_t) -> crate::c_int;
    pub fn pthread_attr_destroy(attr: *mut crate::pthread_attr_t) -> crate::c_int;
    pub fn pthread_attr_setstacksize(attr: *mut crate::pthread_attr_t, stack_size: crate::size_t) -> crate::c_int;
    pub fn pthread_attr_setdetachstate(attr: *mut crate::pthread_attr_t, state: crate::c_int) -> crate::c_int;
    pub fn pthread_detach(thread: crate::pthread_t) -> crate::c_int;
    pub fn pthread_create(
        native: *mut crate::pthread_t,
        attr: *const crate::pthread_attr_t,
        f: extern "C" fn(*mut crate::c_void) -> *mut crate::c_void,
        value: *mut crate::c_void,
    ) -> crate::c_int;
    pub fn pthread_key_create(
        key: *mut pthread_key_t,
        dtor: Option<unsafe extern "C" fn(*mut crate::c_void)>,
    ) -> crate::c_int;
    pub fn pthread_key_delete(key: pthread_key_t) -> crate::c_int;
    pub fn pthread_getspecific(key: pthread_key_t) -> *mut crate::c_void;
    pub fn pthread_setspecific(key: pthread_key_t, value: *const crate::c_void) -> crate::c_int;
    pub fn raise(signum: crate::c_int) -> crate::c_int;

    fn sigaction_external_default(
        sig: crate::c_int,
        sa: *const sigaction,
        old: *mut sigaction,
        _external_handler: Option<unsafe extern "C" fn(crate::c_int)>,
    ) -> crate::c_int;
    fn __wasm_signal(signum: crate::c_int);
}

pub unsafe fn sigaction(sig: crate::c_int, sa: *const sigaction, old: *mut sigaction) -> crate::c_int {
    sigaction_external_default(sig, sa, old, Option::Some(default_handler))
}

extern "C" fn default_handler(sig: crate::c_int) {
    if sig == SIGCHLD || sig == SIGURG || sig == SIGWINCH || sig == SIGCONT {
        return;
    } else {
        unsafe { crate::abort() };
    }
}

/// mocked functions that dont do anything in WASI land
pub fn mlock(_addr: *const crate::c_void, _len: crate::size_t) -> crate::c_int {
    0
}
pub fn munlock(_addr: *const crate::c_void, _len: crate::size_t) -> crate::c_int {
    0
}
pub fn mlockall(_flags: crate::c_int) -> crate::c_int {
    0
}
pub fn munlockall() -> crate::c_int {
    0
}

pub fn WIFSTOPPED(status: crate::c_int) -> bool {
    (status & 0xff) == 0x7f
}

pub fn WSTOPSIG(status: crate::c_int) -> crate::c_int {
    (status >> 8) & 0xff
}

pub fn WIFCONTINUED(status: crate::c_int) -> bool {
    status == 0xffff
}

pub fn WIFSIGNALED(status: crate::c_int) -> bool {
    ((status & 0x7f) + 1) as i8 >= 2
}

pub fn WTERMSIG(status: crate::c_int) -> crate::c_int {
    status & 0x7f
}

pub fn WIFEXITED(status: crate::c_int) -> bool {
    (status & 0x7f) == 0
}

pub fn WEXITSTATUS(status: crate::c_int) -> crate::c_int {
    (status >> 8) & 0xff
}

pub fn WCOREDUMP(status: crate::c_int) -> bool {
    (status & 0x80) != 0
}

pub fn W_EXITCODE(ret: crate::c_int, sig: crate::c_int) -> crate::c_int {
    (ret << 8) | sig
}

pub fn W_STOPCODE(sig: crate::c_int) -> crate::c_int {
    (sig << 8) | 0x7f
}

pub fn QCMD(cmd: crate::c_int, type_: crate::c_int) -> crate::c_int {
    (cmd << 8) | (type_ & 0x00ff)
}
