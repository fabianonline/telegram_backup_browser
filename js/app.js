
angular.module('myApp.controllers', [])
.controller('MainController', function($scope, $location, MtpApiManager, CryptoWorker) {
	var main = this;
	main.loading = false;
	main.step = 1;
	
	main.start = function() {
		MtpApiManager.invokeApi('auth.authorization', {}, {dcID: 2}).then(function(result) {
			debugger;
		}, function(error) {
			debugger;
		});
	}
	
	main.step_1_done = function() {
		main.loading = true;
		console.log('clicked');
		MtpApiManager.invokeApi('auth.sendCode', {
			flags: 0,
			phone_number: main.phone,
			api_id: Config.App.id,
			api_hash: Config.App.hash,
			lang_code: 'en',
		}, {dcID: 2, createNetworker: true}).then(function(result) {
			main.phone_code_hash = result.phone_code_hash;
			main.loading = false;
			main.step = 2;
		});
		return false;
	};
	main.step_2_done = function() {
		main.loading = true;
		console.log('clicked');
		MtpApiManager.invokeApi('auth.signIn', {
			phone_number: main.phone,
			phone_code_hash: main.phone_code_hash,
			phone_code: main.phone_code
		}, {dcID: 2}).then(function(result) {
			debugger;
		}, function(error) {
			if (error.code==401 && error.type=='SESSION_PASSWORD_NEEDED') {
				main.loading = false;
				main.step = 3;
				error.handled = true;
			}
		});
		return false;
	};
	main.step_3_done = function() {
		main.loading = true;
		console.log('Clicked');
		var salt = null;
		MtpApiManager.invokeApi('account.getPassword', {}, {dcID: 2}).then(function(result) {
			debugger;
			makePasswordHash(result.current_salt, main.password, CryptoWorker).then(function(hash) {
				MtpApiManager.invokeApi('auth.checkPassword', {
					password_hash: hash
				}, {dcID: 2}).then(function(result) {
					main.user = result.user;
				}, function(error) {
					debugger;
				});
			});
		}, function(error) {
			debugger;
			return;
		});
	}
});

myApp = angular.module('myApp', [
	'izhukov.utils',
	'izhukov.mtproto',
	'izhukov.mtproto.wrapper',
	'myApp.controllers',
	'myApp.i18n'])
.run(function(MtpApiManager) {
	// code here
})
.factory('$modalStack', function() {
	var $modalStack = {};
	$modalStack.dismissAll = function() {}
	return $modalStack;
})
.service('ErrorService', function() {
})
.service('TelegramMeWebService', function() {
	var self = this;
	self.setAuthorized = function(val) { console.log("TelegramMeWebService.setAuthorized(" + val + ")"); };
});

