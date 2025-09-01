import 'logger.dart';
import 'constants.dart';
import 'uri.dart';
import 'utils.dart' as Utils;

class SIP_Settings {
  final String instance_id;
  final String user_agent;
  final String local_ip;

  final SIP_SocketType socket_type;
  final String socket_uri;

  final String host;
  final int port;
  final String? display_name;
  final String username;
  String? password;
  String? realm;
  String? ha1;

  final int register_expires;
  final int no_answer_timeout;
  final int ice_gathering_timeout;
  final bool session_timers;
  final bool use_preloaded_route;

  final SIP_DTMFMode dtmf_mode;
  final SIP_Method session_refresh;
  final List<Map<String, String>> ice_servers;

  final URI sip_uri;
  final URI registrar_server;
  final URI contact_uri;

  // Приватный конструктор
  SIP_Settings._({
    required this.instance_id,
    required this.user_agent,
    required this.local_ip,
    required this.socket_type,
    required this.socket_uri,
    required this.sip_uri,
    required this.host,
    required this.port,
    required this.username,
    this.display_name,
    this.password,
    this.realm,
    this.ha1,
    required this.register_expires,
    required this.no_answer_timeout,
    required this.ice_gathering_timeout,
    required this.session_timers,
    required this.use_preloaded_route,
    required this.dtmf_mode,
    required this.session_refresh,
    required this.ice_servers,
    required this.contact_uri,
    required this.registrar_server,
  }) {
    logger.wtf('[SETTING] instance_id            = $instance_id');
    logger.wtf('[SETTING] user_agent             = $user_agent');
    logger.wtf('[SETTING] local_ip               = $local_ip');
    logger.wtf('[SETTING] socket_type            = $socket_type');
    logger.wtf('[SETTING] socket_uri             = $socket_uri');
    logger.wtf('[SETTING] sip_uri                = $sip_uri');
    logger.wtf('[SETTING] host                   = $host');
    logger.wtf('[SETTING] port                   = $port');
    logger.wtf('[SETTING] username               = $username');
    logger.wtf('[SETTING] display_name           = $display_name');
    logger.wtf('[SETTING] password               = $password');
    logger.wtf('[SETTING] realm                  = $realm');
    logger.wtf('[SETTING] ha1                    = $ha1');
    logger.wtf('[SETTING] register_expires       = $register_expires');
    logger.wtf('[SETTING] no_answer_timeout      = $no_answer_timeout');
    logger.wtf('[SETTING] ice_gathering_timeout  = $ice_gathering_timeout');
    logger.wtf('[SETTING] session_timers         = $session_timers');
    logger.wtf('[SETTING] use_preloaded_route    = $use_preloaded_route');
    logger.wtf('[SETTING] dtmf_mode              = $dtmf_mode');
    logger.wtf('[SETTING] session_refresh        = $session_refresh');
    logger.wtf('[SETTING] ice_servers            = $ice_servers');
    logger.wtf('[SETTING] contact_uri            = $contact_uri');
    logger.wtf('[SETTING] registrar_server       = $registrar_server');
  }

  static Future<SIP_Settings> create({
    String? instance_id,
    String? user_agent,
    String? local_ip,
    SIP_SocketType socket_type = SIP_SocketType.WS,
    required String socket_uri,
    required String sip_uri,
    String? display_name,
    required String password,
    String? realm,
    String? ha1,
    int register_expires = 20,
    int no_answer_timeout = 60 * 1000,
    int ice_gathering_timeout = 500,
    bool session_timers = false,
    bool use_preloaded_route = false,
    SIP_DTMFMode dtmf_mode = SIP_DTMFMode.RTP,
    SIP_Method session_refresh = SIP_Method.UPDATE,
    List<Map<String, String>> ice_servers = const [],
  }) async {
    final sipUri = URI.parse(sip_uri) as URI;
    final resolvedLocalIp = local_ip ?? await Utils.getLocalIpAddress();
    final resolvedInstanceId = instance_id ?? Utils.newUUID();
    final resolvedUserAgent = user_agent ?? 'SIP-Client v2.0.0';
    final host = sipUri.host;
    final port = sipUri.port ?? 5060;

    final contact = URI(
      'sip',
      Utils.createRandomToken(8),
      resolvedLocalIp,
      null,
      {
        'transport': 
          socket_type == SIP_SocketType.WS 
          ? 'wss'
          : socket_type == SIP_SocketType.TCP 
          ? 'tcp'
          : socket_type == SIP_SocketType.UDP 
          ? 'udp'
          : 'invalid'
      },
    );

    URI registrar_server = sipUri.clone();
    registrar_server.user = null;

    return SIP_Settings._(
      instance_id: resolvedInstanceId,
      user_agent: resolvedUserAgent,
      local_ip: resolvedLocalIp,
      socket_type: socket_type,
      socket_uri: socket_uri,
      sip_uri: sipUri,
      host: host,
      port: port,
      display_name: display_name ?? sipUri.user,
      username: sipUri.user!,
      password: password,
      realm: realm,
      ha1: ha1,
      register_expires: register_expires,
      no_answer_timeout: no_answer_timeout,
      ice_gathering_timeout: ice_gathering_timeout,
      session_timers: session_timers,
      use_preloaded_route: use_preloaded_route,
      dtmf_mode: dtmf_mode,
      session_refresh: session_refresh,
      ice_servers: ice_servers,
      contact_uri: contact,
      registrar_server: registrar_server,
    );
  }
}
