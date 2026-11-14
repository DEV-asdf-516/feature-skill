import java.util.List;

public record QuoteEditNotification(long quoteId, List<String> changedFields) {}
