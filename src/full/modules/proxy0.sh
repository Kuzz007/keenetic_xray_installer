configure_proxy0() {
    echo "[7/10] Настраиваем Proxy0..."

    if ! command -v ndmc >/dev/null 2>&1; then
        echo "ПРЕДУПРЕЖДЕНИЕ: ndmc не найден. Proxy0 настройте вручную."
        return 0
    fi

    if ndmc -c "interface $PROXY_IFACE" \
        && ndmc -c "interface $PROXY_IFACE proxy protocol socks5" \
        && ndmc -c "interface $PROXY_IFACE proxy socks5-udp" \
        && ndmc -c "interface $PROXY_IFACE proxy upstream $ROUTER_LAN_IP $SOCKS_PORT" \
        && ndmc -c "interface $PROXY_IFACE description Xray-Failover" \
        && ndmc -c "interface $PROXY_IFACE no ip global" \
        && ndmc -c "interface $PROXY_IFACE up" \
        && ndmc -c "system configuration save"
    then
        echo "$PROXY_IFACE -> SOCKS5 $ROUTER_LAN_IP:$SOCKS_PORT"
    else
        echo "ПРЕДУПРЕЖДЕНИЕ: Proxy0 не удалось полностью настроить. Проверьте вручную."
        return 0
    fi
}
