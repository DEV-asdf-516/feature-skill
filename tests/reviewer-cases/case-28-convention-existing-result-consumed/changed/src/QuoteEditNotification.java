import java.util.ArrayList;
import java.util.List;

public record QuoteEditNotification(long quoteId, List<String> changedFields) {
  public static QuoteEditNotification of(long quoteId, List<ChangeLogEntry> changes) {
    return new QuoteEditNotification(quoteId, fieldNames(changes));
  }

  private static List<String> fieldNames(List<ChangeLogEntry> changes) {
    List<String> names = new ArrayList<>();
    for (ChangeLogEntry change : changes) names.add(change.field());
    return names;
  }
}
