import static org.junit.jupiter.api.Assertions.assertEquals;
import org.junit.jupiter.api.Test;

class TagParserTest {
  @Test
  void normalize_trimsAndLowercases() {
    assertEquals("java", TagParser.normalize("  Java "));
  }
}
