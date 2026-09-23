public interface ClientRepository {
  java.util.Optional<Client> findById(long id);
  void save(Client client);
}
