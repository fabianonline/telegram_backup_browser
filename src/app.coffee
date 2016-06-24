window.angular.module('myApp.controllers', [])
.controller('MainController', ($scope, $location, MtpApiManager, CryptoWorker, $timeout) ->
	window.mainController = @;
	main = @
	@loading = false
	@step = 1
	@log = ""
	@status = ""
	@db = null
	@user = null
	
	## Run at startup
	
	localStorage.setItem("dc", 2) unless localStorage.getItem("dc")?
	
	@set_status("Checking login state")
	MtpApiManager.invokeApi(
		'account.updateProfile',
		{},
		{}
	).then (result) =>
		@save_auth(result)
	.catch (error) =>
		@set_status("You are not logged in.")
		@user = null
		error.handled = true
	
	## End of run at startup
	
	@set_status = (status) =>
		@log = "#{(new Date()).toString()} --- #{status}\n#{@log}"
	
	@clear_status = =>
		# do nothing
		
	@save_auth = (user) =>
		@set_status("You are logged in as #{user.first_name} #{user.last_name} #{"(@#{user.username})" if user.username}")
		@user = user
		@open_database(user)
		MtpApiManager.setUserAuth(2, {id: user.id})
	
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
			@save_auth(result.user)
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
					@save_auth(result.user)
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
				@download_messages()
	
	@download_messages = =>
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
		.catch(@handle_errors)
	
	@download_missing_media = =>
		@set_status("Fetching all messages with media from cache...")
		@db.messages.filter((x)->x.media?).toArray().then (array) =>
			@set_status("Found #{array.length} messages with media.")
			@set_status("Filtering by media type...")
			new_array = array.filter (elm) =>
				return true if (
					elm.media._=="messageMediaPhoto" ||
					elm.media._=="messageMediaDocument"
				)
				return false if (
					elm.media._=="messageMediaWebPage" ||
					elm.media._=="messageMediaGeo" ||
					elm.media._=="messageMediaContact" ||
					elm.media._=="messageMediaVenue"
				)
				@set_status("Unsupported media type: #{elm.media._}")
				return false
			@set_status("Remaining messages with stuff to download: #{new_array.length}")
			@set_status("Checking the cache for already downloaded files...")
			files = []
			@db.files.toCollection().primaryKeys().then (file_ids) ->
				files = file_ids
			.catch( -> )
			.finally =>
				@media_to_download = new_array.filter (elm) -> files.indexOf(elm.id)==-1
				@set_status("Remaining messages with not-yet-downloaded stuff: #{@media_to_download.length}")
				@progress_name = "Media to download"
				@progress_max = @media_to_download.length
				@progress_current = 0
				@download_first_media()
	
	@download_first_media = =>
		if @media_to_download.length == 0
			@set_status("Done.")
			@progress_name = ""
			return
		message = @media_to_download.shift()
		if message.media.photo?
			biggest = null
			message.media.photo.sizes.forEach (size) ->
				if size.size<=1024*1024 && (
					biggest==null || (
						size.h>=biggest.h && 
						size.w>=biggest.w
					))
					biggest = size
			if biggest==null
				@set_status("Couldn't find image size for id #{message.id}")
				@download_next_media()
			@download_file_with_location(
				message.id,
				biggest.location,
				"image/jpg",
				"jpg")
		else if message.media.document?
			if message.media.document.size >= 1024*1024
				@set_status("Document of message #{message.id} is more than 1 MByte. Skipping.")
				@download_next_media()
				return
			@download_file_without_location(
				message.id,
				message.media.document)
		else
			@set_status("Unhandled media type: #{message.media._}")
			@download_next_media()
	
	@download_file_without_location = (id, data_obj) =>
		file = data_obj.file_name
		ext = ""
		unless file?
			ext = "." + data_obj.mime_type.split('/')[1]
			ext = "" if ext==".octet-stream"
			file = "t_#{data_obj.type||'file'}#{data_obj.id}#{ext}"
		loc = {
			_: "inputDocumentFileLocation",
			id: data_obj.id,
			access_hash: data_obj.access_hash,
			file_name: file,
			dc_id: data_obj.dc_id,
			size: data_obj.size}
		@download_file_with_location(id, loc, data_obj.mime_type, ext.substr(1))	
	
	@download_file_with_location = (id, location, mimetype, ext) =>
		location._ = "inputFileLocation" if (location._==null || location._=="fileLocation")
		MtpApiManager.invokeApi(
			'upload.getFile',
			{
				location: location,
				offset: 0,
				limit: 1024*1024
			},
			{
				dcID: location.dc_id,
				fileDownload: true,
				createNetworker: true,
				noErrorBox: true
			}).then (result) =>
				@db.files.put({
					id: id,
					filetype: ext,
					mimetype: mimetype,
					data: btoa(@ab2str(result.bytes))
				}).finally(@download_next_media)
			.catch(@handle_errors)
	
	@download_next_media = =>
		@progress_current++
		@download_first_media()
		
	@download_json = =>
		@set_status("Creating ZIP file. This may take a few seconds...")
		zip = new Zlib.Zip()
		@db.messages.toArray().then (result) =>
			zip.addFile(
				@str2ab(JSON.stringify(result)),
				{
					filename: @str2ab("data.json")
				})
			@set_status("Adding all available media files...")
			@db.files.toArray().then (files) =>
				@progress_name = "Media files to add"
				@progress_max = files.length
				@progress_current = 0
				files.forEach (file) =>
					filename = "#{file.id}"
					filename = "#{filename}.#{file.filetype}" if file.filetype? && file.filetype!=""
					zip.addFile(
						@str2ab(atob(file.data)),
						{
							filename: @str2ab(filename)
						})
					@progress_current++
				data = zip.compress()
				data = URL.createObjectURL(new File([data], "telegram_backup.zip", {type: 'application/zip'}))
				location.href = data
				@set_status("Done")
				@progress_name = ""
		.catch(@handle_errors)
	
	@handle_errors = (error) =>
		@set_status("An error occured: " + JSON.stringify(error))
		console.log(error)
		error.handled = true
	
	@open_database = (user) =>
		@db = new Dexie("telegram_backup_#{user.id}")
		@db.version(1).stores({
			messages: 'id,date',
			chats: 'id',
			people: 'id',
			files: 'id'
		})
		@db.open().catch(@handle_errors)		
	
	@test = =>
		$.getScript('test.js', => doTest(@) )

	@str2ab = (str) ->
		array = new (if window.Uint8Array? then Uint8Array else Array)(str.length)
		array[i] = str.charCodeAt(i) & 0xff for i in [0...str.length]
		return array

	@ab2str = (array) ->
		target = new Array(array.length)
		target[i] = String.fromCharCode(array[i]) for i in [0...array.length]
		return target.join("")
	
	return null
)

`
myApp = angular.module('myApp', [
	'izhukov.utils',
	'izhukov.mtproto',
	'izhukov.mtproto.wrapper',
	'myApp.controllers',
	'myApp.i18n'])
.run(function(MtpApiManager) {})
.factory('$modalStack', function() {
	$modalStack = {};
	$modalStack.dismissAll = function() {};
	return $modalStack;
}).service('ErrorService', function() {}
).service('TelegramMeWebService', function() {
	this.setAuthorized = function(val) {
		console.log("TelegramMeWebService.setAuthorized(#{val})")
	}
});
`
