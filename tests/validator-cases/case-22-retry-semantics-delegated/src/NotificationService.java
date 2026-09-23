public class NotificationService {
  private final ClientRepository repo;
  private final SmsGateway gateway;
  public NotificationService(ClientRepository repo, SmsGateway gateway) { this.repo = repo; this.gateway = gateway; }
}
