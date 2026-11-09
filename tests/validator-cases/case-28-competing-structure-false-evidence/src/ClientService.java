public class ClientService {
  private final ClientRepository repo;
  public ClientService(ClientRepository repo) { this.repo = repo; }

  public long register(String name, String phone) {
    return repo.insert(name, phone);
  }

  public String maskedPhone(String phone) { return MaskingUtil.maskPhone(phone); }

  public void updatePhone(long id, String phone) {
    repo.updatePhone(id, PhoneNormalizer.normalize(phone));
  }
}
