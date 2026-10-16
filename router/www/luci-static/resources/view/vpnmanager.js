'use strict';
'require view';

// Header button "VPN Manager": jumps to the VLESS manager served on port 90 of this router.
return view.extend({
	render: function() {
		var url = window.location.protocol + '//' + window.location.hostname + ':90/';
		window.location.href = url;
		return E('p', {}, [ _('Opening the VPN Manager… '), E('a', { 'href': url }, url) ]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
