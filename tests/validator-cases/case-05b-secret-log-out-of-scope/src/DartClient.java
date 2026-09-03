public class DartClient {
  private final String apiKey;
  public DartClient(String apiKey) { this.apiKey = apiKey; }
  public String lookup(String name) {
    String url = "https://dart.example/api?crtfc_key=" + apiKey + "&name=" + name;
    return HttpClientSupport.get(url);
  }
}
