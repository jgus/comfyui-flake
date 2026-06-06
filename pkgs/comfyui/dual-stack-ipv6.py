def _hl_install_dual_stack_ipv6():
    import socket
    orig = socket.socket.setsockopt
    ipv6, v6only = socket.IPPROTO_IPV6, socket.IPV6_V6ONLY

    def setsockopt(self, level, optname, value, *a, **kw):
        if level == ipv6 and optname == v6only and value:
            return
        return orig(self, level, optname, value, *a, **kw)

    socket.socket.setsockopt = setsockopt


_hl_install_dual_stack_ipv6()
del _hl_install_dual_stack_ipv6
