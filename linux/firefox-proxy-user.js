// Профиль Firefox «только через прокси».
// Весь трафик идёт в SOCKS5 127.0.0.1:10808. Если прокси выключен —
// сайты НЕ откроются: прямого выхода нет (failover_direct = false).
// Порт поменяй под свой VPN-клиент (у Happ по умолчанию 10808).
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "127.0.0.1");
user_pref("network.proxy.socks_port", 10808);
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.proxy.http", "");
user_pref("network.proxy.ssl", "");
user_pref("network.proxy.share_proxy_settings", false);
user_pref("network.proxy.no_proxies_on", "localhost, 127.0.0.1, ::1");
user_pref("network.proxy.failover_direct", false);
// localhost — напрямую: иначе ломается вход через OAuth (ответ на localhost уходит в прокси)
user_pref("network.proxy.allow_hijacking_localhost", false);
// DNS только через прокси, без DoH в обход
user_pref("network.trr.mode", 5);
// WebRTC выключен — иначе может выдать настоящий IP
user_pref("media.peerconnection.enabled", false);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.prefetch-next", false);
user_pref("network.predictor.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
// Стартовая страница покажет, с какого IP ты выходишь
user_pref("browser.startup.homepage", "https://ipinfo.io/json");
user_pref("browser.startup.page", 1);
