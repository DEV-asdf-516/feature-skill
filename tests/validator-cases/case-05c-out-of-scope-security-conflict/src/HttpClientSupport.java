public final class HttpClientSupport {
  public static String get(String url) {
    log.info("http get {}", url);
    return Http.send(url);
  }
}
