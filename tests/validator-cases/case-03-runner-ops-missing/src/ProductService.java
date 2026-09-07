public final class ProductService {
  public ProductView view(long id, String name) {
    return new ProductView(id, name);
  }
}
