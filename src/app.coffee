window.angular.module('myApp.controllers', [])
.controller('MainController', ($scope, $location, MtpApiManager, CryptoWorker, $timeout) ->
	window.mainController = @;
	@loading = false;
	@step = 1;
	@log = "";
	@status = "";
	@db = null;
	
	@set_status = (status) =>
		@log = "#{(new Date()).toString()} --- #{status}\n#{@log}"
	
	@clear_status = =>
		# do nothing
	
	@set_status("Checking login state")
	MtpApiManager.invokeApi(
		'account.updateProfile',
		{},
		{}
	).then (result) =>
		@clear_status()
		@user = result
		@open_database(result)
	.catch (error) =>
		@clear_status()
		@user = null
		error.handled = true
	
	@step_1_done = =>
		@loading = true
		MtpApiManager.invokeApi(
			'auth.sendCode',
			{
				flags: 0,
				phone_number: @phone,
				api_id: Config.App.id,
				api_hash: Config.App.hash,
				lang_code: 'en'
			},
			{
				createNetworker: true
			}
		).then (result) =>
			@phone_code_hash = result.phone_code_hash
			@loading = false
			@step = 2
		.catch (error) =>
			if error.code==400 && error.type=='PHONE_PASSWORD_PROTECTED'
				@loading = false
				@step = 3
				error.handled = true
	
	@step_2_done = =>
		@loading = true
		MtpApiManager.invokeApi(
			'auth.signIn',
			{
				phone_number: @phone,
				phone_code_hash: @phone_code_hash,
				phone_code: @phone_code
			},
			{}
		).then (result) =>
			@user = result.user
			@open_database(@user)
		.catch (error) =>
			if error.code==401 && error.type=='SESSION_PASSWORD_NEEDED'
				@loading = false
				@step = 3
				error.handled = true
	
	@step_3_done = =>
		@loading = true
		salt = null
		MtpApiManager.invokeApi(
			'account.getPassword',
			{},
			{}
		).then (result) =>
			makePasswordHash(
				result.current_salt,
				@password,
				CryptoWorker
			).then (hash) =>
				MtpApiManager.invokeApi(
					'auth.checkPassword',
					{
						password_hash: hash
					},
					{}
				).then (result) =>
					@user = result.user
					@open_database(result.user)
				.catch(@handle_errors)
				.finally =>
					@password = null
			.catch(@handle_errors)
	
	@start_download = =>
		@loading = true
		@set_status("Fetching dialogs")
		MtpApiManager.invokeApi(
			'messages.getDialogs',
			{
				offset_date: 0,
				offset_id: 0,
				offset_peer: {_: 'inputPeerEmpty'},
				limit: 100,
				max_id: -1
			},
			{}
		).then(@process_dialog_list)
		.catch(@handle_errors)
	
	@process_dialog_list = (dialogs) =>
		@set_status("Parsing dialog list")
		@set_status("Got #{dialogs.dialogs.length} Chats")
		max_ids = dialogs.dialogs.map((x) -> x.top_message)
		max_id = Math.max.apply(Math, max_ids)
		@set_status("Newest message id at telegram is #{max_id}")
		max_known_id = 0
		@db.messages.orderBy(":id").last().then (last_msg) =>
			max_known_id = last_msg.id
		.catch( -> )
		.finally =>
			@set_status("Newest messages id in cache is #{max_known_id}")
			if max_known_id >= max_id
				@set_status("No new messages. Doing nothing.")
				@loading = false
			else
				@message_ids_to_load = Array.from(new Array(max_id+1).keys()).slice(max_known_id+1)
				@message_count = max_id
				@progress_name = "Messages loaded"
				@progress_max = @message_ids_to_load.length
				@progress_current = 0
				@download_messages
	
	@download_messages =>
		ids = @message_ids_to_load.splice(0, 200)
		@set_status("Downloading #{ids.length} messages, starting with ID=#{ids[0]}...")
		MtpApiManager.invokeApi(
			'messages.getMessages',
			{
				id: ids
			},
			{}
		).then (result) =>
			@temp_result = result
			@set_status("Saving the data...")
			@db.transaction('rw', @db.messages, @db.people, @db.chats, =>
				@db.messages.bulkPut(result.messages)
				@db.people.bulkPut(result.users)
				@db.chats.bulkPut(result.chats)
			).then =>
				@progress_current += ids.length
				if @message_ids_to_load.length > 0
					@set_status("Short delay...")
					$timeout(@download_messages, 750)
				else if @auto_download
					@set_status("Starting auto-download of missing media")
					@download_missing_media()
				else
					@set_status("Done")
					@progress_name = ""
		.catch(handle_errors)
	###	
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
			}).catch(function(e){}).finally(function() {
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
###
)
