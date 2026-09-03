public final class DartHttp {
  public record DartResponse(String status, String message, java.util.List<Item> data) {}
  public record Item(String corpCode, String corpName) {}
  public static DartResponse search(String name) { return Json.read(Http.get("/api/company.json?name=" + name), DartResponse.class); }
}
