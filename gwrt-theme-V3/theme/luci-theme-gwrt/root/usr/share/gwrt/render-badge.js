/* GWRT renderBadge fallback.
 *
 * luci-mod-status (30_network.js / 60_wifi.js) calls renderBadge() from its
 * renderbox() helpers, but the pinned luci-base feed ships no definition for
 * it, so opening Status -> Overview throws
 *   ReferenceError: renderBadge is not defined
 * and the whole overview body stays empty.
 *
 * /etc/init.d/gwrt-theme inserts this function into the stock view files once
 * (marker: "GWRT renderBadge fallback"), so the repair works for the GWRT
 * theme, for the native bootstrap theme on the 81/444 ports and for any LuCI
 * port mapping in /etc/config/gwrt.
 *
 * Signature (derived from both call sites):
 *   renderBadge(iconUrl, badgeText, label1, value1, label2, value2, ...)
 * Labels of null render as an empty cell, values of null render as "-".
 */
function renderBadge(icon, badge) {
	var pairs = Array.prototype.slice.call(arguments, 2);
	var rows = [], i, label, value;

	for (i = 0; i + 1 < pairs.length; i += 2) {
		label = (pairs[i] != null) ? pairs[i] : '';
		value = (pairs[i + 1] != null) ? pairs[i + 1] : '-';
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'style': 'width:33%;vertical-align:top' }, label),
			E('td', { 'class': 'td left', 'style': 'vertical-align:top' }, value)
		]));
	}

	return E('div', { 'class': 'gwrt-render-badge' }, [
		E('div', { 'class': 'gwrt-render-badge-head' }, [
			E('img', {
				'src': icon,
				'alt': '',
				'style': 'width:40px;height:40px;vertical-align:middle;margin-right:8px'
			}),
			(badge != null) ? E('span', { 'style': 'vertical-align:middle' }, badge) : ''
		]),
		E('table', { 'class': 'table', 'style': 'margin:6px 0 0 0' }, rows)
	]);
}
