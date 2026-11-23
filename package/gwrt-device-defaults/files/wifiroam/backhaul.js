'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var getPolicy = rpc.declare({ object: 'wifiroam', method: 'mesh_policy' });
var setPolicy = rpc.declare({
	object: 'wifiroam', method: 'set_mesh_policy',
	params: [ 'search_seconds', 'router_seconds' ]
});

var labels = {
	idle: '路由模式（未进入从 AP 自动切换）',
	search: '待命搜索主 AP',
	wired_pending: '有线已确认，正在获取管理地址',
	wired: '有线回传',
	wireless: '无线回传',
	recover: '正在恢复原路由设置',
	router: '临时恢复原路由模式'
};

function numberInput(id, value) {
	return E('input', {
		id: id, type: 'number', min: 15, max: 3600, step: 1, value: value,
		'class': 'cbi-input-text'
	});
}

return view.extend({
	load: function() {
		return getPolicy().catch(function() { return null; });
	},

	render: function(config) {
		if (!config || !config.mode)
			return E('div', { 'class': 'alert-message warning' }, '无法读取组网状态，请检查无线漫游服务。');

		var state = E('p'), search = numberInput('gwrt-mesh-search', config.search_seconds);
		var router = numberInput('gwrt-mesh-router', config.router_seconds);

		function update(data) {
			var label = labels[data.mode] || '等待状态';
			var duration = data.mode === 'search' ? data.search_seconds :
				data.mode === 'router' ? data.router_seconds : 0;
			if (duration)
				label += ' · 剩余约 ' + Math.max(0, duration - data.elapsed) + ' 秒';
			if (data.ip)
				label += ' · 管理地址 ' + data.ip;
			state.textContent = label;
		}

		var save = E('button', {
			'type': 'button', 'class': 'btn cbi-button cbi-button-save',
			click: function() {
				if (!search.reportValidity() || !router.reportValidity() ||
				    !search.value || !router.value ||
				    !Number.isInteger(Number(search.value)) || !Number.isInteger(Number(router.value))) {
					ui.addNotification(null, E('p', {}, '请输入 15 到 3600 之间的整数秒。'));
					return;
				}
				save.disabled = true;
				return setPolicy(Number(search.value), Number(router.value)).then(function(result) {
					if (!result || !result.ok)
						throw new Error('save');
					ui.addNotification(null, E('p', {}, '等待时间已保存。'), 'info');
				}).catch(function() {
					ui.addNotification(null, E('p', {}, '保存失败，请检查组网服务。'), 'danger');
				}).finally(function() { save.disabled = false; });
			}
		}, '保存');
		update(config);
		poll.add(function() { return getPolicy().then(update).catch(function() {}); }, 5);

		return E('div', {}, [
			E('h2', {}, '回传切换'),
			E('div', { 'class': 'cbi-section' }, [
				state,
				E('p', {}, '从 AP 优先使用接到已配对主 AP 网络的有线口。断开后尝试无线；两路都不可用时，在搜索和原路由模式之间循环。'),
				E('p', {}, [ E('label', { 'for': search.id }, '待命搜索（秒） '), search ]),
				E('p', {}, [ E('label', { 'for': router.id }, '原路由模式停留（秒） '), router ]),
				save
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
