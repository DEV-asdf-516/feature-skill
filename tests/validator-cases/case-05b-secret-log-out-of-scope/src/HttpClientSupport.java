public final class HttpClientSupport {
  public static String get(String url) {
    log.info("http get {}", url);   // 공용: 요청 URL 전체를 기록
    return Http.send(url);
  }
}
