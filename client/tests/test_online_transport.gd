extends SceneTree
## Real TCP/WebSocket server and client in independent Godot processes.
## The literal invitation is an isolated test fixture, never a deployment token.
const Server = preload("res://scripts/online/ws_server.gd")
const Client = preload("res://scripts/online/online_client.gd")
const Wire = preload("res://scripts/online/json_wire.gd")
const TEST_TOKEN := "transport-fixture-not-a-deployment-credential"
var checks := 0
var failures: Array[String] = []
var role := ""
var port := 0
var result_path := ""
var ready_path := ""
var server: Node
var client: Node
var finish_requested := false
var disconnect_count := 0
var auth_count := 0
var observed_inputs := 0
var state_messages: Array[Dictionary] = []
var event_messages: Array[Dictionary] = []
var results: Array[Dictionary] = []
var tls_listener := TCPServer.new()
var tls_options: TLSOptions
var tls_sessions: Array[Dictionary] = []
var tls_unexpected_success := false


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		if argument.begins_with("--port="): port = int(argument.trim_prefix("--port="))
		if argument.begins_with("--result="): result_path = argument.trim_prefix("--result=")
		if argument.begins_with("--ready="): ready_path = argument.trim_prefix("--ready=")
	_run.call_deferred()


func _run() -> void:
	_unit_checks()
	if role.is_empty():
		await _orchestrate()
		return
	if role == "server":
		await _host()
	else:
		await _guest()
	var result := {"suite": "online_transport_" + role, "checks": checks, "failures": failures}
	FileAccess.open(result_path, FileAccess.WRITE).store_string(JSON.stringify(result))
	print(JSON.stringify(result))
	quit(0 if failures.is_empty() else 1)


func _unit_checks() -> void:
	_check(Client.valid_url("ws://127.0.0.1:9080/play") and Client.valid_url("ws://[::1]:9080/play"), "cleartext is allowed only for loopback development")
	_check(Client.valid_url("wss://example.org/play") and Client.valid_url("wss://example.org:443/play"), "public endpoint requires WSS")
	for address: String in ["ws://example.org/play", "ws://192.168.1.10/play", "https://example.org/play", "wss://user:password@example.org/play", "wss://example.org/play?token=secret", "wss://example.org:0/play", "wss://example.org:65536/play", "wss://example.org/play#secret", "ws://localhost.evil/play"]:
		_check(not Client.valid_url(address), "unsafe URL rejected without connecting")
	_check(Wire.decode('{"op":"input","seq":10,"controls":{"pitch":0.5}}'.to_utf8_buffer()).seq is int, "safe integral JSON numbers become strict integers")
	_check(Wire.encode({"op": "input", "seq": 9007199254740992}).is_empty(), "unsafe integer precision is rejected")
	_check(Wire.decode('{"op":"input","seq":9007199254740993}'.to_utf8_buffer()).is_empty(), "out-of-range JSON integer is rejected")
	_check(Wire.encode({"op": "input", "position": Vector3.ZERO}).is_empty(), "Godot objects/vectors cannot enter JSON wire")
	_check(Wire.encode({"op": "input", "value": NAN}).is_empty(), "non-finite outbound number rejected")
	_check(Wire.decode('{invalid'.to_utf8_buffer()).is_empty(), "malformed JSON rejected quietly")
	_check(Wire.decode(('{"op":"chat","text":"' + "x".repeat(16384) + '"}').to_utf8_buffer()).is_empty(), "over16KiB JSON frame rejected")
	_check(Wire.decode(('{"op":"command","args":' + "[".repeat(13) + "0" + "]".repeat(13) + '}').to_utf8_buffer()).is_empty(), "nested JSON allocation is bounded before parsing")
	_check(not Client._valid_controls({"damage": 100}), "input cannot claim damage")
	_check(not Client._valid_controls({"pitch": NAN}) and not Client._valid_controls({"boost": 1}), "controls require finite axes and real booleans")
	_check(Client._valid_controls({"pitch": 0.5, "boost": true, "aim_direction": [0,0,-1]}), "bounded control schema accepted")
	var bucket := {"rates": {}}
	_check(Server._take_rate(bucket,"unit",1,2) and Server._take_rate(bucket,"unit",1,2) and not Server._take_rate(bucket,"unit",1,2), "transport token bucket limits bursts")
	var teardown_client:=Client.new()
	var notifications:={"count":0}
	teardown_client.status_changed.connect(func(_status:String)->void:notifications.count+=1)
	root.add_child(teardown_client)
	teardown_client._set_status("connecting","fixture")
	root.remove_child(teardown_client)
	_check(notifications.count==1 and teardown_client.snapshot().status=="offline","tree teardown clears credentials/state without reentering the owner through disconnect callbacks")
	root.add_child(teardown_client)
	teardown_client._set_status("connecting","fixture")
	_check(notifications.count==2,"reused client resumes status notifications after entering a tree again")
	root.remove_child(teardown_client)
	teardown_client.free()


func _orchestrate() -> void:
	var probe := TCPServer.new()
	var second := TCPServer.new()
	for attempt in range(100):
		var candidate := 20000 + (OS.get_process_id() * 7 + attempt * 101) % 30000
		if probe.listen(candidate,"127.0.0.1") == OK:
			if second.listen(candidate+1,"127.0.0.1") == OK:
				port=candidate
				probe.stop()
				second.stop()
				break
			probe.stop()
	_check(port > 0, "free localhost TCP and TLS ports found")
	var directory := OS.get_cache_dir().path_join("ace-ws-test-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(directory)
	var ready := directory.path_join("ready")
	var host_result := directory.path_join("server.json")
	var guest_result := directory.path_join("client.json")
	var common := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/test_online_transport.gd", "--", "--port=%d" % port, "--ready="+ready]
	var host_args := common.duplicate()
	host_args.append_array(["--role=server","--result="+host_result])
	var host_pid := OS.create_process(OS.get_executable_path(),host_args)
	_check(host_pid>0,"independent WebSocket server process launched")
	var deadline := Time.get_ticks_msec()+10000
	while not FileAccess.file_exists(ready) and Time.get_ticks_msec()<deadline and OS.is_process_running(host_pid):
		await create_timer(0.05).timeout
	_check(FileAccess.file_exists(ready),"server listens before client starts")
	var guest_args := common.duplicate()
	guest_args.append_array(["--role=client","--result="+guest_result])
	var guest_pid := OS.create_process(OS.get_executable_path(),guest_args)
	_check(guest_pid>0,"independent client process launched")
	deadline=Time.get_ticks_msec()+35000
	while (OS.is_process_running(host_pid) or OS.is_process_running(guest_pid)) and Time.get_ticks_msec()<deadline:
		await create_timer(0.05).timeout
	for identifier: int in [host_pid,guest_pid]:
		if OS.is_process_running(identifier):
			OS.kill(identifier)
			_check(false,"worker finished before timeout")
	for path: String in [host_result,guest_result]:
		_check(FileAccess.file_exists(path),"worker result exists")
		if FileAccess.file_exists(path):
			var result: Variant=JSON.parse_string(FileAccess.get_file_as_string(path))
			_check(result is Dictionary and result.get("failures",["missing"]).is_empty(),"worker assertions pass: "+path.get_file())
			if result is Dictionary: checks+=int(result.get("checks",0))
	for path: String in [ready,host_result,guest_result]: DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(directory)
	print(JSON.stringify({"suite":"online_transport","checks":checks,"failures":failures.size(),"independent_processes":2,"transport":"WebSocket JSON localhost","untrusted_tls_certificate_rejected":true}))
	for failure: String in failures: printerr(failure)
	quit(0 if failures.is_empty() else 1)


func _host() -> void:
	server=Server.new()
	root.add_child(server)
	server.message_received.connect(_server_message)
	server.disconnected.connect(func(_id: int): disconnect_count+=1)
	_check(server.start(port,"127.0.0.1")==OK,"raw WebSocket server listens")
	var crypto:=Crypto.new()
	var key:=crypto.generate_rsa(2048)
	var certificate:=crypto.generate_self_signed_certificate(key,"CN=localhost,O=ACE Test,C=BR","20200101000000","20400101000000")
	tls_options=TLSOptions.server(key,certificate)
	_check(tls_listener.listen(port+1,"127.0.0.1")==OK,"self-signed TLS fixture listens independently")
	FileAccess.open(ready_path,FileAccess.WRITE).store_string("ready")
	var deadline:=Time.get_ticks_msec()+30000
	while not finish_requested and Time.get_ticks_msec()<deadline:
		_poll_tls()
		await create_timer(0.01).timeout
	_check(finish_requested,"authenticated client completes reconnect exchange")
	await create_timer(0.15).timeout
	var state:Dictionary=server.snapshot()
	_check(observed_inputs>=2 and auth_count>=3,"transport authenticates and dispatches real inputs across connections")
	_check(state.metrics.invalid_frames>=4,"malformed/binary/oversized/preauth frames are rejected")
	_check(state.metrics.rate_limited>=1,"server rejects raw input flood independently of client limiter")
	_check(state.metrics.capacity_rejected>=1,"pending TCP capacity is capped")
	_check(state.metrics.timed_out>=2,"TCP handshake and authentication have actual timeouts")
	_check(disconnect_count>=4,"connection cleanup emits disconnection notifications")
	_check(not tls_unexpected_success,"untrusted TLS never carries client WebSocket/authentication data")
	_check(not JSON.stringify(state).contains(TEST_TOKEN),"metrics contain no invitation token")
	server.stop()
	_check(server.snapshot().connections==0 and not server.snapshot().running,"stop closes listener and all connections")
	tls_listener.stop()
	for session:Dictionary in tls_sessions: (session.tcp as StreamPeerTCP).disconnect_from_host()
	server.queue_free()
	await create_timer(0.2).timeout


func _server_message(identifier:int,value:Dictionary) -> void:
	match str(value.op):
		"auth":
			if value.get("protocol")==Wire.PROTOCOL and value.get("token")==TEST_TOKEN:
				auth_count+=1
				server.mark_authenticated(identifier)
				server.send_to(identifier,{"op":"auth_ok","pilot_id":"fixture-pilot"})
				server.send_to(identifier,{"op":"snapshot","state":{"connection_id":identifier,"tick":1}})
			else:server.disconnect_peer(identifier,"auth_failed")
		"input":
			observed_inputs+=1
			server.send_to(identifier,{"op":"snapshot","state":{"connection_id":identifier,"ack":value.get("seq"),"controls":value.get("controls",{})}})
		"command":
			server.send_to(identifier,{"op":"result","request_id":value.request_id,"ok":true,"action":value.action})
			if value.action=="finish":finish_requested=true
		"chat":server.send_to(identifier,{"op":"event","event":{"type":"chat","text":value.text,"pilot_id":"fixture-pilot"}})


func _poll_tls() -> void:
	while tls_listener.is_connection_available():
		var tcp:=tls_listener.take_connection()
		var tls:=StreamPeerTLS.new()
		var old_errors:=Engine.print_error_messages
		Engine.print_error_messages=false
		var accepted:=tls.accept_stream(tcp,tls_options)
		Engine.print_error_messages=old_errors
		if accepted==OK:tls_sessions.append({"tcp":tcp,"tls":tls})
	for index in range(tls_sessions.size()-1,-1,-1):
		var session:Dictionary=tls_sessions[index]
		var tls:StreamPeerTLS=session.tls
		var old_errors:=Engine.print_error_messages
		Engine.print_error_messages=false # Expected certificate rejection is asserted below.
		tls.poll()
		Engine.print_error_messages=old_errors
		if tls.get_status()==StreamPeerTLS.STATUS_CONNECTED and tls.get_available_bytes()>0:tls_unexpected_success=true
		if tls.get_status() in [StreamPeerTLS.STATUS_ERROR,StreamPeerTLS.STATUS_DISCONNECTED]:
			(session.tcp as StreamPeerTCP).disconnect_from_host()
			tls_sessions.remove_at(index)


func _guest() -> void:
	client=Client.new()
	root.add_child(client)
	client.snapshot_received.connect(func(value:Dictionary):state_messages.append(value))
	client.event_received.connect(func(value:Dictionary):event_messages.append(value))
	client.command_result.connect(func(value:Dictionary):results.append(value))
	_check(client.connect_to("ws://example.org/play",TEST_TOKEN)==ERR_INVALID_PARAMETER,"client cannot leak an invitation to public cleartext WebSocket")
	_check(not client.send_input(0,{}) and not client.send_chat("offline"),"offline messages are not reported as delivered")
	await _invalid_raw_frames()
	await _pending_and_timeout_checks()
	var old_errors:=Engine.print_error_messages
	Engine.print_error_messages=false # This test intentionally presents an untrusted cert.
	_check(client.connect_to("wss://localhost:%d/play"%(port+1),TEST_TOKEN)==OK,"WSS fixture begins normal verified TLS handshake")
	var deadline:=Time.get_ticks_msec()+4000
	while client.snapshot().status!="error" and Time.get_ticks_msec()<deadline:
		await create_timer(0.01).timeout
	Engine.print_error_messages=old_errors
	_check(client.snapshot().status=="error" and not client.is_connected_to_server(),"untrusted TLS certificate is rejected without bypass")
	_check(client._pending_token.is_empty(),"failed TLS clears pending invitation")
	_check(client.connect_to("ws://127.0.0.1:%d/play"%port,TEST_TOKEN)==OK,"real loopback WebSocket connects")
	_check(await _wait_connected(),"hello/auth/auth_ok handshake succeeds")
	_check(client._pending_token.is_empty() and not JSON.stringify(client.snapshot()).contains(TEST_TOKEN),"token is absent from client snapshot after authentication")
	_check(client.send_input(1,{"pitch":0.5,"boost":true,"aim_direction":[0,0,-1]}),"client transmits validated flight controls")
	_check(not client.send_input(1,{}) and not client.send_input(2,{"hp":999}),"duplicate sequence and resource claims are rejected locally")
	_check(client.command("request-one","echo",{"text":"ação"}) and client.send_chat("Olá sessão"),"commands and session chat use real socket")
	deadline=Time.get_ticks_msec()+3000
	while (not _has_ack(1) or event_messages.is_empty() or results.is_empty()) and Time.get_ticks_msec()<deadline:
		await create_timer(0.01).timeout
	_check(_has_ack(1) and not event_messages.is_empty() and not results.is_empty(),"snapshot/event/command-result signals receive server data")
	var first_id:int=state_messages.back().get("connection_id",0) if not state_messages.is_empty() else 0
	client.disconnect_from_server()
	_check(client.snapshot().state.is_empty() and client.snapshot().pilot_id.is_empty(),"disconnect clears online state and identity")
	await create_timer(0.1).timeout
	state_messages.clear()
	_check(client.connect_to("ws://127.0.0.1:%d/play"%port,TEST_TOKEN)==OK and await _wait_connected(),"client reconnects without restarting game")
	_check(client.send_input(1,{"brake":true}),"input sequence resets only for a new transport session")
	deadline=Time.get_ticks_msec()+3000
	while not _has_ack(1) and Time.get_ticks_msec()<deadline:await create_timer(0.01).timeout
	var second_id:int=state_messages.back().get("connection_id",0) if not state_messages.is_empty() else 0
	_check(first_id>0 and second_id>first_id,"reconnection gets a new transport ID")
	_check(client.command("request-finish","finish"),"finish command reaches server")
	deadline=Time.get_ticks_msec()+3000
	while client.snapshot().status!="error" and Time.get_ticks_msec()<deadline:await create_timer(0.01).timeout
	_check(client.snapshot().status=="error" and client.snapshot().state.is_empty(),"host stop clears client authoritative snapshot")
	client.queue_free()
	await process_frame


func _wait_connected() -> bool:
	var deadline:=Time.get_ticks_msec()+3000
	while not client.is_connected_to_server() and Time.get_ticks_msec()<deadline and client.snapshot().status!="error":await create_timer(0.01).timeout
	return client.is_connected_to_server()


func _has_ack(sequence:int) -> bool:
	for state:Dictionary in state_messages:
		if int(state.get("ack",-1))==sequence:return true
	return false


func _raw_open() -> WebSocketPeer:
	var peer:=WebSocketPeer.new()
	peer.connect_to_url("ws://127.0.0.1:%d/play"%port)
	var deadline:=Time.get_ticks_msec()+2000
	while peer.get_ready_state()==WebSocketPeer.STATE_CONNECTING and Time.get_ticks_msec()<deadline:
		peer.poll()
		await create_timer(0.01).timeout
	return peer


func _raw_close_wait(peer:WebSocketPeer,duration:float=2.0) -> bool:
	var deadline:=Time.get_ticks_msec()+int(duration*1000)
	while peer.get_ready_state()!=WebSocketPeer.STATE_CLOSED and Time.get_ticks_msec()<deadline:
		peer.poll()
		await create_timer(0.01).timeout
	return peer.get_ready_state()==WebSocketPeer.STATE_CLOSED


func _invalid_raw_frames() -> void:
	for kind:String in ["malformed","binary","oversized","preauth"]:
		var peer:=await _raw_open()
		_check(peer.get_ready_state()==WebSocketPeer.STATE_OPEN,"raw malicious fixture opens TCP/WebSocket")
		match kind:
			"malformed":peer.send_text("{invalid")
			"binary":peer.send(PackedByteArray([1,2,3]))
			"oversized":peer.send_text("x".repeat(17000))
			"preauth":peer.send_text('{"op":"input","seq":1,"controls":{}}')
		_check(await _raw_close_wait(peer),"server disconnects invalid "+kind+" frame")
	var flood:=await _raw_open()
	flood.send_text(Wire.encode({"op":"auth","protocol":Wire.PROTOCOL,"token":TEST_TOKEN}))
	await create_timer(0.05).timeout
	flood.poll()
	for sequence in range(12):flood.send_text(Wire.encode({"op":"input","seq":sequence,"controls":{}}))
	_check(await _raw_close_wait(flood),"authenticated raw input flood is bounded")


func _pending_and_timeout_checks() -> void:
	var sockets:Array[StreamPeerTCP]=[]
	for index in range(9):
		var tcp:=StreamPeerTCP.new()
		tcp.connect_to_host("127.0.0.1",port)
		sockets.append(tcp)
		await create_timer(0.025).timeout
	await create_timer(0.1).timeout
	sockets.back().poll()
	var ninth_read:Array=sockets.back().get_partial_data(1)
	_check(ninth_read[0]!=OK or sockets.back().get_status()!=StreamPeerTCP.STATUS_CONNECTED,"ninth pending TCP connection is rejected")
	for tcp:StreamPeerTCP in sockets:tcp.disconnect_from_host()
	await create_timer(0.1).timeout
	var preauth:=await _raw_open()
	var unfinished:=StreamPeerTCP.new()
	unfinished.connect_to_host("127.0.0.1",port)
	_check(await _raw_close_wait(preauth,10.0),"open WebSocket without authentication expires after8s")
	unfinished.poll()
	var closed_read:Array=unfinished.get_partial_data(1)
	_check(closed_read[0]!=OK or unfinished.get_status()!=StreamPeerTCP.STATUS_CONNECTED,"incomplete TCP/WebSocket handshake expires after5s")
	unfinished.disconnect_from_host()


func _check(value:bool,label:String) -> void:
	checks+=1
	if not value:failures.append(label)
