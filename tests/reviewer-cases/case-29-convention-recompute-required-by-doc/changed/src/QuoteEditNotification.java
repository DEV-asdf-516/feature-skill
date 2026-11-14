import java.util.ArrayList;
import java.util.List;

public record QuoteEditNotification(long quoteId, List<String> changedFields) {
  public static QuoteEditNotification of(Quote before, QuoteUpdate update) {
    List<String> fields = new ArrayList<>();
    if (!before.title().equals(update.title())) fields.add("title");
    if (before.amount() != update.amount()) fields.add("amount");
    if (!before.dueDate().equals(update.dueDate())) fields.add("dueDate");
    return new QuoteEditNotification(before.id(), fields);
  }
}
