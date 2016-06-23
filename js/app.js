
angular.module('myApp.controllers', [])
.controller('MainController', function($scope, $location, MtpApiManager, CryptoWorker, $timeout) {
	var main = this;
	window.mainController = this;
	main.loading = false;
	main.step = 1;
	main.log = "";
	main.status = "";
	main.data = {};
	main.db = null;
	
	main.set_status = function(status) {
		main.log = (new Date()).toString() + " --- " + status + "\n" + main.log;
	}
	
	main.clear_status = function() {
		//main.set_status("");
	}
	
	main.set_status("Checking login state");
	MtpApiManager.invokeApi('account.updateProfile', {}, {}).then(function(result) {
		main.clear_status();
		main.user = result;
		main.open_database(result);
	}, function(error) {
		main.clear_status();
		main.user = null;
		error.handled = true;
	});
	
	main.step_1_done = function() {
		main.loading = true;
		console.log('clicked');
		MtpApiManager.invokeApi('auth.sendCode', {
			flags: 0,
			phone_number: main.phone,
			api_id: Config.App.id,
			api_hash: Config.App.hash,
			lang_code: 'en',
		}, {createNetworker: true}).then(function(result) {
			main.phone_code_hash = result.phone_code_hash;
			main.loading = false;
			main.step = 2;
		}, function(error) {
			if (error.code==400 && error.type=='PHONE_PASSWORD_PROTECTED') {
				main.loading = false;
				main.step = 3;
				error.handled = true;
			}
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
		}, {}).then(function(result) {
			main.open_database(result.user);
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
		MtpApiManager.invokeApi('account.getPassword', {}, {}).then(function(result) {
			makePasswordHash(result.current_salt, main.password, CryptoWorker).then(function(hash) {
				MtpApiManager.invokeApi('auth.checkPassword', {
					password_hash: hash
				}, {}).then(function(result) {
					main.user = result.user;
					main.open_database(result.user);
				}, main.handle_errors);
			});
		}, function(error) {
			debugger;
			return;
		});
	}
	
	main.start_download = function() {
		main.loading = true;
		main.set_status("Fetching dialogs");
		var dialogs = MtpApiManager.invokeApi('messages.getDialogs', {
			offset_date: 0,
			offset_id: 0,
			offset_peer: {_: 'inputPeerEmpty'},
			limit: 100,
			max_id: -1
		}, {}).then(main.process_dialog_list, main.handle_errors);
	}
	
	main.process_dialog_list = function(dialogs) {
		main.set_status("Parsing dialog list");
		main.set_status("Got " + dialogs.dialogs.length + " Chats");
		var max_ids = dialogs.dialogs.map(function(x) {return x.top_message});
		var max_id = Math.max.apply(Math, max_ids);
		main.set_status("Newest message id at telegram is " + max_id);
		var max_known_id = 0;
		main.db.messages.orderBy(":id").last().then(function(last_msg) {
			max_known_id = last_msg.id;
		}).catch(function(e){/*ignore this error*/}).finally(function() {
			main.set_status("Newest message id in cache is " + max_known_id);
			if (max_known_id>=max_id) {
				main.set_status("No new messages. Doing nothing.");
				main.loading = false;
			} else {
				main.message_ids_to_load = Array.from(new Array(max_id+1).keys()).slice(max_known_id+1);
				main.message_count = max_id;
				main.progress_name = "Messages loaded";
				main.progress_max = main.message_ids_to_load.length;
				main.progress_current = 0;
				main.data = {messages: [], chats: {}, users: {}};
				main.download_messages();
			}
		});
	}
	
	main.download_messages = function() {
		var ids = main.message_ids_to_load.splice(0, 200);
		main.set_status("Downloading " + ids.length + " messages, starting with ID=" + ids[0] + "...");
		MtpApiManager.invokeApi('messages.getMessages', {id: ids}, {}).then(function(result) {
			main.temp_result = result;
			main.set_status("Saving the data...");
			main.db.transaction('rw', main.db.messages, main.db.people, main.db.chats, function() {
				main.db.messages.bulkPut(result.messages);
				main.db.people.bulkPut(result.users);
				main.db.chats.bulkPut(result.chats);
			}).then(function() {
				main.progress_current += ids.length;
				if (main.message_ids_to_load.length > 0) {
					main.set_status("Short delay...");
					$timeout(main.download_messages, 2000);
				} else if (main.auto_download) {
					main.set_status("Starting auto-download of missing media");
					main.download_missing_media();
				} else {
					main.set_status("Done.");
					main.clear_status();
					main.progress_name = "";
				}
			});
		}, main.handle_errors);
	}
	
	main.download_missing_media = function() {
		main.set_status("Fetching all messages with media from cache...");
		main.db.messages.filter(function(x){return x.media!=null;}).toArray().then(function(array) {
			main.set_status("Found " + array.length + " messages with media.");
			main.set_status("Filtering stuff to download...");
			var new_array = array.filter(function(elm) {
				if (
					elm.media._=="messageMediaPhoto" || 
					elm.media._=="messageMediaDocument"
				) return true;
				
				if (
					elm.media._=="messageMediaWebPage" ||
					elm.media._=="messageMediaGeo"
				) return false;
				
				main.set_status("Unsupported media: " + elm.media._);
				return false;
			});
			main.set_status("Remaining messages with stuff to download: " + new_array.length);
			main.set_status("Checking the cache for already downloaded files...");
			var files = [];
			main.db.files.toCollection().primaryKeys().then(function(f){
				files = f;
			}).catch(function(e){/*do nothing*/}).finally(function() {
				main.media_to_download = new_array.filter(function(elm) { return files.indexOf(elm.id)==-1; });
				main.set_status("Remaining messages with not-yet-downloaded stuff: " + main.media_to_download.length);
				main.progress_name = "Media to download";
				main.progress_max = main.media_to_download.length;
				main.progress_current = 0;
				main.download_first_media();
			});
		});
	}
	
	main.download_first_media = function() {
		if (main.media_to_download.length == 0) {
			main.set_status("Done.");
			main.progress_name = "";
		}
		var message = main.media_to_download.shift();
		if (message.media.photo) {
			// Select the biggest photo size
			var biggest = null;
			message.media.photo.sizes.forEach(function(size) {
				if (biggest==null || (size.h>=biggest.h && size.w>=biggest.w && size.size<=1024*1024)) biggest=size;
			});
			main.download_file_with_location(message.id, biggest.location, "image/jpg", "jpg");
		} else if (message.media.document) {
			if (message.media.document.size >= 1024*1024) {
				main.set_status("Document of message " + message.id + " is bigger than 1 MByte. Skipping.");
				main.download_next_media();
				return;
			}
			main.download_file_without_location(message.id, message.media.document);
			
		} else {
			main.set_status("Unknown media type: " + message.media._);
			main.download_next_media();
		}
	}
	
	main.download_file_without_location = function(id, data_obj) {
		var file = data_obj.file_name;
		var ext = '';
		if (file==null) {
			ext = '.' + data_obj.mime_type.split('/')[1];
			if (ext=='.octet-stream') ext='';
			file = "t_" + (data_obj.type || 'file') + data_obj.id + ext;
		}
			
		var loc = {_: "inputDocumentFileLocation", id: data_obj.id, access_hash: data_obj.access_hash, file_name: file, dc_id: data_obj.dc_id, size: data_obj.size};
		
		main.download_file_with_location(id, loc, data_obj.mimetype, ext.substr(1));
	}
	
	main.download_file_with_location = function(id, location, mimetype, filetype) {
		if (location._==null || location._=="fileLocation") location._ = "inputFileLocation";
		MtpApiManager.invokeApi(
			'upload.getFile',
			{location: location, offset: 0, limit: 1024*1024},
			{dcID: location.dc_id, fileDownload: true, createNetworker: true, noErrorBox: true}
		).then(function(result) {
			main.db.files.put(
				{id: id, filetype: filetype, mimetype: mimetype, data: btoa(main.ab2str(result.bytes))}
			).finally(main.download_next_media);
		}).catch(main.handle_errors);
	}
	
	main.download_next_media = function() {
		main.progress_current++;
		main.download_first_media();
	}
	
	main.download_json = function() {
		main.set_status("Creating ZIP file. This may take a few seconds...");
		var zip = new Zlib.Zip();
		main.db.messages.toArray().then(function(result) {
			zip.addFile(main.str2ab(JSON.stringify(result)), { filename: main.str2ab("data.json") });
			
			main.set_status("Adding media files...");
			main.db.files.toArray().then(function(files) {
				main.progress_name = "Media files to add";
				main.progress_max = files.length;
				main.progress_current = 0;
				files.forEach(function(file) {
					var filename = "" + file.id;
					if (file.filetype && file.filetype!=null) filename += "." + file.filetype;
					console.log(typeof file.data);
					zip.addFile(main.str2ab(atob(file.data)), { filename: main.str2ab(filename) });
					main.progress_current++;
				});
				var data = zip.compress();
				data = URL.createObjectURL(new Blob([data], {type: 'application/zip'}));
				location.href = data;
			}).catch(main.handle_errors);
		}).catch(main.handle_errors);
	}
			
	
	main.handle_errors = function(error) {
		console.log(error);
		debugger;
	}
	
	main.open_database = function(user) {
		main.db = new Dexie("telegram_backup_" + user.id);
		main.db.version(1).stores({
			messages: 'id,date',
			chats: 'id',
			people: 'id',
			files: 'id'
		});
		main.db.open().catch(main.handle_errors);
	}
	
	main.test = function() {
		$.getScript('test.js', function() { doTest(main); });
	}
	
	main.str2ab = function(str) {
		var array = new (window.Uint8Array !== void 0 ? Uint8Array : Array)(str.length);
		for (var i=0; i<str.length; i++) array[i] = str.charCodeAt(i) & 0xff;
		return array;
	}
	
	main.ab2str = function(array) {
		var target = new Array(array.length);
		for (var i=0; i<array.length; i++) target[i] = String.fromCharCode(array[i]);
		return target.join('');
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

