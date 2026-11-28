/* GWRT: "return to GWRT theme" shortcut for the native bootstrap theme.
 *
 * Ports mapped to bootstrap in /etc/config/gwrt (gwrt.theme.port_81 = 81,
 * gwrt.theme.port_444 = 444) hide the GWRT navigation, including the theme
 * switch offered on the GWRT login page, so there is no way back without
 * editing the URL.  /etc/init.d/gwrt-theme appends this file to
 * /www/luci-static/resources/cbi.js, which the bootstrap header loads on
 * every page (marker: GWRT native return link).  Pages that already use the
 * GWRT stylesheet are left untouched.
 */
(function () {
	'use strict';

	var RETURN_PORTS = { '81': '80', '444': '443' };

	function onGwrtTheme() {
		var links = document.querySelectorAll('link[rel="stylesheet"]');
		for (var i = 0; i < links.length; i++)
			if ((links[i].getAttribute('href') || '').indexOf('/luci-static/gwrt/') !== -1)
				return true;
		return false;
	}

	function returnUrl() {
		var port = RETURN_PORTS[location.port] || location.port;
		var host = location.hostname + (port ? ':' + port : '');
		return location.protocol + '//' + host + location.pathname + location.search;
	}

	function inject() {
		if (onGwrtTheme() || document.getElementById('gwrt-theme-return'))
			return;

		var host = document.getElementById('indicators') ||
			document.querySelector('header .nav') ||
			document.querySelector('header') ||
			document.body;
		if (!host)
			return;

		var link = document.createElement('a');
		link.id = 'gwrt-theme-return';
		link.className = 'btn gwrt-theme-return';
		link.href = returnUrl();
		link.title = '打开 GWRT 主题界面';
		link.style.cssText = 'margin-left:8px;white-space:nowrap;vertical-align:middle';
		link.appendChild(document.createTextNode('返回 GWRT'));
		host.appendChild(link);
	}

	if (document.readyState === 'loading')
		document.addEventListener('DOMContentLoaded', inject);
	else
		inject();
}());
