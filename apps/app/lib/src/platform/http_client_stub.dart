import 'package:http/http.dart' as http;

http.Client createPlatformHttpClient() => http.Client();

String defaultAxApiBaseUrl() => 'http://localhost:8787/api';

bool get managesNativeSessionCookie => true;
