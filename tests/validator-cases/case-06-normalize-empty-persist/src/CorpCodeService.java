public class CorpCodeService {
  private final ClientRepository repo;
  public void assign(long clientId, String rawCode) {
    String normalized = rawCode.replaceAll("[^0-9]", "");
    repo.saveCorpCode(clientId, normalized);
  }
}
