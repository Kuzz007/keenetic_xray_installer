#!/bin/sh

set -e

PROXY_IFACE="Proxy0"
POLICY_NAME="Policy0"
INSTALL_PATH="/opt/bin/xray-keenetic-routes"
SYNC_LINK="/opt/bin/xray-routes-sync"
CLEAR_LINK="/opt/bin/xray-routes-clear"
STATUS_LINK="/opt/bin/xray-routes-status"
BACKUP_DIR="/opt/etc/xray/route-backups"

need_ndmc() {
    if ! command -v ndmc >/dev/null 2>&1; then
        echo "ОШИБКА: ndmc не найден. Скрипт нужно запускать на Keenetic/Entware."
        exit 1
    fi
}

run_ndmc() {
    echo "+ ndmc -c \"$1\""
    ndmc -c "$1"
}

quiet_ndmc() {
    ndmc -c "$1" >/dev/null 2>&1 || true
}

backup_config() {
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/running-config-before-xray-routes-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now).txt"
    echo "Backup running-config: $BACKUP_FILE"
    ndmc -c "show running-config" > "$BACKUP_FILE"
}

cidr_to_mask() {
    prefix="$1"
    case "$prefix" in
        0) echo "0.0.0.0" ;;
        1) echo "128.0.0.0" ;;
        2) echo "192.0.0.0" ;;
        3) echo "224.0.0.0" ;;
        4) echo "240.0.0.0" ;;
        5) echo "248.0.0.0" ;;
        6) echo "252.0.0.0" ;;
        7) echo "254.0.0.0" ;;
        8) echo "255.0.0.0" ;;
        9) echo "255.128.0.0" ;;
        10) echo "255.192.0.0" ;;
        11) echo "255.224.0.0" ;;
        12) echo "255.240.0.0" ;;
        13) echo "255.248.0.0" ;;
        14) echo "255.252.0.0" ;;
        15) echo "255.254.0.0" ;;
        16) echo "255.255.0.0" ;;
        17) echo "255.255.128.0" ;;
        18) echo "255.255.192.0" ;;
        19) echo "255.255.224.0" ;;
        20) echo "255.255.240.0" ;;
        21) echo "255.255.248.0" ;;
        22) echo "255.255.252.0" ;;
        23) echo "255.255.254.0" ;;
        24) echo "255.255.255.0" ;;
        25) echo "255.255.255.128" ;;
        26) echo "255.255.255.192" ;;
        27) echo "255.255.255.224" ;;
        28) echo "255.255.255.240" ;;
        29) echo "255.255.255.248" ;;
        30) echo "255.255.255.252" ;;
        31) echo "255.255.255.254" ;;
        32) echo "255.255.255.255" ;;
        *) echo ""; return 1 ;;
    esac
}

ip_route_parts() {
    item="$1"
    case "$item" in
        */*)
            network="${item%/*}"
            prefix="${item#*/}"
            mask="$(cidr_to_mask "$prefix")"
            if [ -z "$mask" ]; then
                return 1
            fi
            if [ "$prefix" = "32" ]; then
                echo "$network"
            else
                echo "$network $mask"
            fi
            ;;
        *)
            echo "$item"
            ;;
    esac
}

domain_data() {
cat <<'DATA'
D|domain-list80|xray-ai-domains|chat.com
D|domain-list80|xray-ai-domains|chatgpt.com
D|domain-list80|xray-ai-domains|oaistatic.com
D|domain-list80|xray-ai-domains|oaiusercontent.com
D|domain-list80|xray-ai-domains|openai.com
D|domain-list80|xray-ai-domains|sora.com
D|domain-list81|xray-apple-domains|aaplimg.com
D|domain-list81|xray-apple-domains|apple-cloudkit.com
D|domain-list81|xray-apple-domains|apple-dns.com
D|domain-list81|xray-apple-domains|apple-dns.net
D|domain-list81|xray-apple-domains|apple.com
D|domain-list81|xray-apple-domains|appstore.com
D|domain-list81|xray-apple-domains|cdn-apple.com
D|domain-list81|xray-apple-domains|icloud.com
D|domain-list81|xray-apple-domains|icloud-content.com
D|domain-list81|xray-apple-domains|itunes.apple.com
D|domain-list81|xray-apple-domains|mzstatic.com
D|domain-list81|xray-apple-domains|shazam.com
D|domain-list82|xray-discord-domains|dis.gd
D|domain-list82|xray-discord-domains|discord.com
D|domain-list82|xray-discord-domains|discord.gg
D|domain-list82|xray-discord-domains|discord.media
D|domain-list82|xray-discord-domains|discordapp.com
D|domain-list82|xray-discord-domains|discordapp.net
D|domain-list82|xray-discord-domains|discordcdn.com
D|domain-list83|xray-gemini-domains|ai.google.dev
D|domain-list83|xray-gemini-domains|ai.studio
D|domain-list83|xray-gemini-domains|aistudio.google.com
D|domain-list83|xray-gemini-domains|bard.google.com
D|domain-list83|xray-gemini-domains|deepmind.com
D|domain-list83|xray-gemini-domains|deepmind.google
D|domain-list83|xray-gemini-domains|gemini.google
D|domain-list83|xray-gemini-domains|gemini.google.com
D|domain-list83|xray-gemini-domains|generativeai.google
D|domain-list83|xray-gemini-domains|jules.google
D|domain-list83|xray-gemini-domains|jules.google.com
D|domain-list83|xray-gemini-domains|labs.google
D|domain-list83|xray-gemini-domains|labs.google.com
D|domain-list83|xray-gemini-domains|notebooklm.google
D|domain-list83|xray-gemini-domains|notebooklm.google.com
D|domain-list83|xray-gemini-domains|opal.google
D|domain-list83|xray-gemini-domains|opal.google.com
D|domain-list83|xray-gemini-domains|stitch.withgoogle.com
D|domain-list84|xray-meta-domains|aboutfacebook.com
D|domain-list84|xray-meta-domains|facebook.com
D|domain-list84|xray-meta-domains|facebook.net
D|domain-list84|xray-meta-domains|fb.com
D|domain-list84|xray-meta-domains|fbcdn.com
D|domain-list84|xray-meta-domains|fbcdn.net
D|domain-list84|xray-meta-domains|instagram.com
D|domain-list84|xray-meta-domains|cdninstagram.com
D|domain-list84|xray-meta-domains|ig.me
D|domain-list84|xray-meta-domains|igcdn.com
D|domain-list84|xray-meta-domains|messenger.com
D|domain-list84|xray-meta-domains|m.me
D|domain-list84|xray-meta-domains|meta.ai
D|domain-list84|xray-meta-domains|meta.com
D|domain-list84|xray-meta-domains|threads.com
D|domain-list84|xray-meta-domains|threads.net
D|domain-list84|xray-meta-domains|wa.me
D|domain-list84|xray-meta-domains|whatsapp.com
D|domain-list84|xray-meta-domains|whatsapp.net
D|domain-list85|xray-telegram-domains|cdn-telegram.org
D|domain-list85|xray-telegram-domains|comments.app
D|domain-list85|xray-telegram-domains|contest.com
D|domain-list85|xray-telegram-domains|fragment.com
D|domain-list85|xray-telegram-domains|graph.org
D|domain-list85|xray-telegram-domains|t.me
D|domain-list85|xray-telegram-domains|tdesktop.com
D|domain-list85|xray-telegram-domains|telegra.ph
D|domain-list85|xray-telegram-domains|telegram-cdn.org
D|domain-list85|xray-telegram-domains|telegram.dog
D|domain-list85|xray-telegram-domains|telegram.me
D|domain-list85|xray-telegram-domains|telegram.org
D|domain-list85|xray-telegram-domains|telegram.space
D|domain-list85|xray-telegram-domains|telesco.pe
D|domain-list85|xray-telegram-domains|tg.dev
D|domain-list85|xray-telegram-domains|ton.org
D|domain-list86|xray-youtube-domains|googlevideo.com
D|domain-list86|xray-youtube-domains|i.ytimg.com
D|domain-list86|xray-youtube-domains|manifest.googlevideo.com
D|domain-list86|xray-youtube-domains|m.youtube.com
D|domain-list86|xray-youtube-domains|music.youtube.com
D|domain-list86|xray-youtube-domains|s.youtube.com
D|domain-list86|xray-youtube-domains|studio.youtube.com
D|domain-list86|xray-youtube-domains|tv.youtube.com
D|domain-list86|xray-youtube-domains|wide-youtube.l.google.com
D|domain-list86|xray-youtube-domains|www.youtube.com
D|domain-list86|xray-youtube-domains|youtu.be
D|domain-list86|xray-youtube-domains|youtube-nocookie.com
D|domain-list86|xray-youtube-domains|youtube.com
D|domain-list86|xray-youtube-domains|youtube.googleapis.com
D|domain-list86|xray-youtube-domains|youtubei.googleapis.com
D|domain-list86|xray-youtube-domains|ytimg.com
D|domain-list86|xray-youtube-domains|ytimg.googleusercontent.com
DATA
}

ip_data() {
cat <<'DATA'
I|ip-list80|xray-akamai-ips|2.16.0.0/13
I|ip-list80|xray-akamai-ips|23.0.0.0/12
I|ip-list80|xray-akamai-ips|23.32.0.0/11
I|ip-list80|xray-akamai-ips|23.64.0.0/14
I|ip-list80|xray-akamai-ips|23.72.0.0/13
I|ip-list80|xray-akamai-ips|23.192.0.0/11
I|ip-list80|xray-akamai-ips|60.254.128.0/18
I|ip-list80|xray-akamai-ips|69.192.0.0/16
I|ip-list80|xray-akamai-ips|69.22.150.0/23
I|ip-list80|xray-akamai-ips|69.31.112.0/23
I|ip-list80|xray-akamai-ips|69.31.118.0/24
I|ip-list80|xray-akamai-ips|69.31.122.0/24
I|ip-list80|xray-akamai-ips|72.246.0.0/15
I|ip-list80|xray-akamai-ips|84.53.128.0/18
I|ip-list80|xray-akamai-ips|88.221.0.0/16
I|ip-list80|xray-akamai-ips|92.122.0.0/15
I|ip-list80|xray-akamai-ips|95.100.0.0/15
I|ip-list80|xray-akamai-ips|96.6.0.0/15
I|ip-list80|xray-akamai-ips|96.16.0.0/15
I|ip-list80|xray-akamai-ips|104.64.0.0/10
I|ip-list80|xray-akamai-ips|118.214.0.0/16
I|ip-list80|xray-akamai-ips|118.215.0.0/17
I|ip-list80|xray-akamai-ips|118.215.128.0/18
I|ip-list80|xray-akamai-ips|125.56.184.0/23
I|ip-list80|xray-akamai-ips|125.56.191.0/24
I|ip-list80|xray-akamai-ips|125.56.192.0/18
I|ip-list80|xray-akamai-ips|165.254.0.0/24
I|ip-list80|xray-akamai-ips|165.254.2.0/24
I|ip-list80|xray-akamai-ips|165.254.26.128/26
I|ip-list80|xray-akamai-ips|165.254.40.0/23
I|ip-list80|xray-akamai-ips|165.254.44.0/23
I|ip-list80|xray-akamai-ips|165.254.52.0/24
I|ip-list80|xray-akamai-ips|165.254.58.0/25
I|ip-list80|xray-akamai-ips|165.254.81.0/24
I|ip-list80|xray-akamai-ips|165.254.110.0/23
I|ip-list80|xray-akamai-ips|165.254.119.128/25
I|ip-list80|xray-akamai-ips|165.254.123.0/24
I|ip-list80|xray-akamai-ips|165.254.136.0/24
I|ip-list80|xray-akamai-ips|165.254.142.0/24
I|ip-list80|xray-akamai-ips|165.254.145.64/26
I|ip-list80|xray-akamai-ips|165.254.156.0/23
I|ip-list80|xray-akamai-ips|165.254.203.192/26
I|ip-list80|xray-akamai-ips|165.254.237.128/25
I|ip-list80|xray-akamai-ips|165.254.238.128/25
I|ip-list80|xray-akamai-ips|165.254.247.128/25
I|ip-list80|xray-akamai-ips|172.224.0.0/12
I|ip-list80|xray-akamai-ips|173.222.0.0/15
I|ip-list80|xray-akamai-ips|184.24.0.0/13
I|ip-list80|xray-akamai-ips|184.50.0.0/15
I|ip-list80|xray-akamai-ips|184.84.0.0/14
I|ip-list80|xray-akamai-ips|192.33.24.0/22
I|ip-list80|xray-akamai-ips|192.33.28.0/23
I|ip-list80|xray-akamai-ips|192.33.30.0/24
I|ip-list80|xray-akamai-ips|193.108.88.0/21
I|ip-list80|xray-akamai-ips|193.108.152.0/22
I|ip-list80|xray-akamai-ips|198.47.116.0/24
I|ip-list80|xray-akamai-ips|199.46.32.0/19
I|ip-list80|xray-akamai-ips|204.2.139.0/24
I|ip-list80|xray-akamai-ips|204.2.145.0/24
I|ip-list80|xray-akamai-ips|204.2.158.0/23
I|ip-list80|xray-akamai-ips|204.2.162.0/24
I|ip-list80|xray-akamai-ips|204.2.164.0/23
I|ip-list80|xray-akamai-ips|204.2.196.0/24
I|ip-list80|xray-akamai-ips|204.237.142.0/23
I|ip-list80|xray-akamai-ips|204.237.186.0/23
I|ip-list80|xray-akamai-ips|204.237.188.0/24
I|ip-list80|xray-akamai-ips|209.200.128.0/18
I|ip-list81|xray-apple-ips|17.0.0.0/8
I|ip-list82|xray-amazon-ips|13.224.0.0/12
I|ip-list82|xray-amazon-ips|13.249.0.0/16
I|ip-list82|xray-amazon-ips|18.154.0.0/15
I|ip-list82|xray-amazon-ips|18.160.0.0/13
I|ip-list82|xray-amazon-ips|18.172.0.0/15
I|ip-list82|xray-amazon-ips|52.84.0.0/14
I|ip-list82|xray-amazon-ips|54.192.0.0/12
I|ip-list82|xray-amazon-ips|64.252.64.0/18
I|ip-list82|xray-amazon-ips|64.252.128.0/18
I|ip-list82|xray-amazon-ips|65.8.0.0/16
I|ip-list82|xray-amazon-ips|65.9.0.0/17
I|ip-list82|xray-amazon-ips|75.2.0.0/17
I|ip-list82|xray-amazon-ips|76.223.0.0/17
I|ip-list82|xray-amazon-ips|99.84.0.0/16
I|ip-list82|xray-amazon-ips|99.86.0.0/16
I|ip-list83|xray-cloudflare-ips|103.21.244.0/22
I|ip-list83|xray-cloudflare-ips|103.22.200.0/22
I|ip-list83|xray-cloudflare-ips|103.31.4.0/22
I|ip-list83|xray-cloudflare-ips|104.16.0.0/13
I|ip-list83|xray-cloudflare-ips|104.24.0.0/14
I|ip-list83|xray-cloudflare-ips|108.162.192.0/18
I|ip-list83|xray-cloudflare-ips|131.0.72.0/22
I|ip-list83|xray-cloudflare-ips|141.101.64.0/18
I|ip-list83|xray-cloudflare-ips|162.158.0.0/15
I|ip-list83|xray-cloudflare-ips|172.64.0.0/13
I|ip-list83|xray-cloudflare-ips|173.245.48.0/20
I|ip-list83|xray-cloudflare-ips|188.114.96.0/20
I|ip-list83|xray-cloudflare-ips|190.93.240.0/20
I|ip-list83|xray-cloudflare-ips|197.234.240.0/22
I|ip-list83|xray-cloudflare-ips|198.41.128.0/17
I|ip-list84|xray-fastly-ips|23.235.32.0/20
I|ip-list84|xray-fastly-ips|43.249.72.0/22
I|ip-list84|xray-fastly-ips|103.244.50.0/24
I|ip-list84|xray-fastly-ips|103.245.222.0/23
I|ip-list84|xray-fastly-ips|103.245.224.0/24
I|ip-list84|xray-fastly-ips|104.156.80.0/20
I|ip-list84|xray-fastly-ips|140.248.64.0/18
I|ip-list84|xray-fastly-ips|140.248.128.0/17
I|ip-list84|xray-fastly-ips|146.75.0.0/17
I|ip-list84|xray-fastly-ips|151.101.0.0/16
I|ip-list84|xray-fastly-ips|157.52.64.0/18
I|ip-list84|xray-fastly-ips|167.82.0.0/17
I|ip-list84|xray-fastly-ips|167.82.128.0/20
I|ip-list84|xray-fastly-ips|167.82.160.0/20
I|ip-list84|xray-fastly-ips|167.82.224.0/20
I|ip-list84|xray-fastly-ips|172.111.64.0/18
I|ip-list84|xray-fastly-ips|185.31.16.0/22
I|ip-list84|xray-fastly-ips|199.27.72.0/21
I|ip-list84|xray-fastly-ips|199.232.0.0/16
I|ip-list85|xray-meta-ips|31.13.24.0/21
I|ip-list85|xray-meta-ips|31.13.64.0/18
I|ip-list85|xray-meta-ips|45.64.40.0/22
I|ip-list85|xray-meta-ips|57.141.0.0/20
I|ip-list85|xray-meta-ips|57.141.16.0/22
I|ip-list85|xray-meta-ips|57.141.20.0/23
I|ip-list85|xray-meta-ips|57.144.0.0/14
I|ip-list85|xray-meta-ips|66.220.144.0/20
I|ip-list85|xray-meta-ips|69.63.176.0/20
I|ip-list85|xray-meta-ips|69.171.224.0/19
I|ip-list85|xray-meta-ips|74.119.76.0/22
I|ip-list85|xray-meta-ips|102.132.96.0/20
I|ip-list85|xray-meta-ips|102.132.112.0/24
I|ip-list85|xray-meta-ips|102.132.115.0/24
I|ip-list85|xray-meta-ips|102.132.116.0/23
I|ip-list85|xray-meta-ips|102.132.119.0/24
I|ip-list85|xray-meta-ips|102.132.120.0/23
I|ip-list85|xray-meta-ips|102.132.123.0/24
I|ip-list85|xray-meta-ips|102.132.125.0/24
I|ip-list85|xray-meta-ips|102.132.126.0/24
I|ip-list85|xray-meta-ips|102.221.188.0/22
I|ip-list85|xray-meta-ips|103.4.96.0/22
I|ip-list85|xray-meta-ips|129.134.0.0/17
I|ip-list85|xray-meta-ips|157.240.0.0/17
I|ip-list85|xray-meta-ips|157.240.128.0/23
I|ip-list85|xray-meta-ips|157.240.131.0/24
I|ip-list85|xray-meta-ips|157.240.132.0/24
I|ip-list85|xray-meta-ips|157.240.134.0/24
I|ip-list85|xray-meta-ips|157.240.136.0/23
I|ip-list85|xray-meta-ips|157.240.139.0/24
I|ip-list85|xray-meta-ips|157.240.140.0/24
I|ip-list85|xray-meta-ips|157.240.156.0/22
I|ip-list85|xray-meta-ips|157.240.169.0/24
I|ip-list85|xray-meta-ips|157.240.170.0/24
I|ip-list85|xray-meta-ips|157.240.175.0/24
I|ip-list85|xray-meta-ips|157.240.177.0/24
I|ip-list85|xray-meta-ips|157.240.179.0/24
I|ip-list85|xray-meta-ips|157.240.181.0/24
I|ip-list85|xray-meta-ips|157.240.182.0/23
I|ip-list85|xray-meta-ips|157.240.184.0/21
I|ip-list85|xray-meta-ips|157.240.192.0/18
I|ip-list85|xray-meta-ips|163.70.128.0/17
I|ip-list85|xray-meta-ips|173.252.64.0/18
I|ip-list85|xray-meta-ips|179.60.192.0/22
I|ip-list85|xray-meta-ips|185.60.216.0/22
I|ip-list85|xray-meta-ips|199.201.64.0/22
I|ip-list85|xray-meta-ips|204.15.20.0/22
I|ip-list86|xray-telegram-ips|91.105.192.0/23
I|ip-list86|xray-telegram-ips|91.108.4.0/22
I|ip-list86|xray-telegram-ips|91.108.8.0/21
I|ip-list86|xray-telegram-ips|91.108.16.0/21
I|ip-list86|xray-telegram-ips|91.108.56.0/22
I|ip-list86|xray-telegram-ips|95.161.64.0/20
I|ip-list86|xray-telegram-ips|149.154.160.0/20
I|ip-list86|xray-telegram-ips|185.76.151.0/24
I|ip-list87|xray-youtube-ips|64.233.160.0/19
I|ip-list87|xray-youtube-ips|66.102.0.0/20
I|ip-list87|xray-youtube-ips|66.249.64.0/19
I|ip-list87|xray-youtube-ips|72.14.192.0/18
I|ip-list87|xray-youtube-ips|74.125.0.0/16
I|ip-list87|xray-youtube-ips|108.170.192.0/18
I|ip-list87|xray-youtube-ips|108.177.0.0/17
I|ip-list87|xray-youtube-ips|142.250.0.0/15
I|ip-list87|xray-youtube-ips|172.217.0.0/16
I|ip-list87|xray-youtube-ips|172.253.0.0/16
I|ip-list87|xray-youtube-ips|173.194.0.0/16
I|ip-list87|xray-youtube-ips|192.178.0.0/15
I|ip-list87|xray-youtube-ips|208.65.152.0/22
I|ip-list87|xray-youtube-ips|208.117.224.0/19
I|ip-list87|xray-youtube-ips|209.85.128.0/17
I|ip-list87|xray-youtube-ips|216.58.192.0/19
I|ip-list87|xray-youtube-ips|216.239.32.0/19
DATA
}

for_each_domain_group() {
    for group in domain-list80 domain-list81 domain-list82 domain-list83 domain-list84 domain-list85 domain-list86; do
        echo "$group"
    done
}

for_each_ip_group() {
    for group in ip-list80 ip-list81 ip-list82 ip-list83 ip-list84 ip-list85 ip-list86 ip-list87; do
        echo "$group"
    done
}

remove_policy_route() {
    route_parts="$1"

    # KeeneticOS on different versions accepts different delete forms.
    # The most reliable forms are the short ones without interface/auto.
    quiet_ndmc "ip policy $POLICY_NAME no route $route_parts"
    quiet_ndmc "no ip policy $POLICY_NAME route $route_parts"

    # Extra compatibility attempts. Errors are intentionally hidden.
    quiet_ndmc "ip policy $POLICY_NAME no route $route_parts $PROXY_IFACE"
    quiet_ndmc "ip policy $POLICY_NAME no route $route_parts $PROXY_IFACE auto"
    quiet_ndmc "no ip policy $POLICY_NAME route $route_parts $PROXY_IFACE"
    quiet_ndmc "no ip policy $POLICY_NAME route $route_parts $PROXY_IFACE auto"
}

clear_routes_nosave() {
    echo "Удаляем наши FQDN routes и domain-list80..86..."
    for_each_domain_group | while read -r group; do
        quiet_ndmc "dns-proxy no route object-group $group $PROXY_IFACE auto"
        quiet_ndmc "no dns-proxy route object-group $group $PROXY_IFACE auto"
        quiet_ndmc "no object-group fqdn $group"
    done

    echo "Удаляем наши IP routes и ip-list80..87..."
    ip_data | while IFS='|' read -r kind group desc item; do
        [ "$kind" = "I" ] || continue
        route_parts="$(ip_route_parts "$item")" || continue
        remove_policy_route "$route_parts"
    done

    remove_policy_route "1.1.1.1"
    remove_policy_route "1.0.0.0 255.255.255.0"

    for_each_ip_group | while read -r group; do
        quiet_ndmc "no object-group ip $group"
    done
}

sync_routes() {
    need_ndmc

    echo
    echo "======================================"
    echo " Xray Keenetic Routes sync"
    echo "======================================"
    echo "Proxy interface: $PROXY_IFACE"
    echo "Policy: $POLICY_NAME"
    echo

    backup_config
    clear_routes_nosave

    echo
    echo "Создаём FQDN groups и DNS proxy routes..."
    domain_data | while IFS='|' read -r kind group desc domain; do
        [ "$kind" = "D" ] || continue
        quiet_ndmc "object-group fqdn $group"
        quiet_ndmc "object-group fqdn $group description $desc"
        quiet_ndmc "object-group fqdn $group include $domain"
    done

    for_each_domain_group | while read -r group; do
        echo "Route FQDN group $group -> $PROXY_IFACE"
        quiet_ndmc "dns-proxy route object-group $group $PROXY_IFACE auto"
    done

    echo
    echo "Создаём IP groups и Policy0 routes..."
    ip_data | while IFS='|' read -r kind group desc item; do
        [ "$kind" = "I" ] || continue
        route_parts="$(ip_route_parts "$item")" || {
            echo "Пропуск некорректного CIDR: $item"
            continue
        }

        quiet_ndmc "object-group ip $group"
        quiet_ndmc "object-group ip $group description $desc"
        quiet_ndmc "object-group ip $group include ip $item"
        quiet_ndmc "ip policy $POLICY_NAME route $route_parts $PROXY_IFACE auto"
    done

    echo
    echo "Сохраняем конфигурацию Keenetic..."
    run_ndmc "system configuration save"

    echo
    echo "Готово."
    echo "Проверка: xray-routes-status"
}

clear_routes() {
    need_ndmc

    echo
    echo "======================================"
    echo " Xray Keenetic Routes clear"
    echo "======================================"
    echo

    backup_config
    clear_routes_nosave

    echo
    echo "Сохраняем конфигурацию Keenetic..."
    run_ndmc "system configuration save"

    echo
    echo "Готово. Наши auto routes/groups удалены."
}

status_routes() {
    need_ndmc

    echo
    echo "FQDN groups domain-list80..86:"
    ndmc -c "show running-config" | grep -E "object-group fqdn domain-list8[0-6]|description xray-.*-domains|route object-group domain-list8[0-6]" || true

    echo
    echo "IP groups ip-list80..87:"
    ndmc -c "show running-config" | grep -E "object-group ip ip-list8[0-7]|description xray-.*-ips|include ip " | head -n 120 || true

    echo
    echo "Policy0 routes through $PROXY_IFACE, first 120 lines:"
    ndmc -c "show running-config" | grep -A800 "ip policy $POLICY_NAME" | grep "route .* $PROXY_IFACE auto" | head -n 120 || true
}

install_self() {
    mkdir -p /opt/bin

    if [ "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$INSTALL_PATH" ]; then
        cp "$0" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
    else
        chmod +x "$INSTALL_PATH"
    fi

    ln -sf "$INSTALL_PATH" "$SYNC_LINK"
    ln -sf "$INSTALL_PATH" "$CLEAR_LINK"
    ln -sf "$INSTALL_PATH" "$STATUS_LINK"

    echo
    echo "Установлены команды:"
    echo "$SYNC_LINK"
    echo "$CLEAR_LINK"
    echo "$STATUS_LINK"
    echo
    echo "Запуск синхронизации:"
    echo "xray-routes-sync"
}

cmd="${1:-sync}"
base="$(basename "$0")"

case "$base" in
    xray-routes-sync) cmd="sync" ;;
    xray-routes-clear) cmd="clear" ;;
    xray-routes-status) cmd="status" ;;
esac

case "$cmd" in
    install)
        install_self
        ;;
    sync)
        sync_routes
        ;;
    clear)
        clear_routes
        ;;
    status)
        status_routes
        ;;
    *)
        echo "Использование: $0 {install|sync|clear|status}"
        echo
        echo "Команды после install:"
        echo "  xray-routes-sync"
        echo "  xray-routes-clear"
        echo "  xray-routes-status"
        exit 1
        ;;
esac
