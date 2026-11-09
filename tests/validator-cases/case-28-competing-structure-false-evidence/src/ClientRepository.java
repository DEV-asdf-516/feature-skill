public interface ClientRepository {
  long insert(String name, String phone);
  void updatePhone(long id, String phone);
}
