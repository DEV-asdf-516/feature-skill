import java.util.Optional;

public interface QuoteRepository {
  Optional<Quote> findById(long id);
  void save(Quote quote);
}
