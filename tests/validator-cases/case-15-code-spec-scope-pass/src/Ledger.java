import java.util.List;
import java.util.Map;

public class Ledger {
  private final Map<Long, List<Entry>> byAccount;
  private final StringBuilder auditLog = new StringBuilder();
  public Ledger(Map<Long, List<Entry>> byAccount) { this.byAccount = byAccount; }
  public List<Entry> entries(long accountId) { return byAccount.getOrDefault(accountId, List.of()); }
  public void audit(String message) { auditLog.append(message).append('\n'); }
  public String auditLog() { return auditLog.toString(); }
}
