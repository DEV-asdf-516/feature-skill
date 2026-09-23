public class NotificationService {
  private final ClientRepository repo;
  private final SmsGateway gateway;
  public NotificationService(ClientRepository repo, SmsGateway gateway) { this.repo = repo; this.gateway = gateway; }

  private enum Kind { SENT, SKIPPED }

  private record SendOutcome(Kind kind, String phone) {}

  public SendStatus send(long id) {
    Client client = repo.findById(id).orElseThrow(() -> new NotFoundException("client " + id));
    SendOutcome outcome = resultOf(client);
    if (outcome.kind() == Kind.SENT) {
      gateway.send(outcome.phone(), "안내 메시지");
      return SendStatus.SENT;
    }
    return SendStatus.SKIPPED_NO_PHONE;
  }

  private SendOutcome resultOf(Client client) {
    if (client.phone().isEmpty()) {
      return new SendOutcome(Kind.SKIPPED, client.phone());
    }
    return new SendOutcome(Kind.SENT, client.phone());
  }
}
