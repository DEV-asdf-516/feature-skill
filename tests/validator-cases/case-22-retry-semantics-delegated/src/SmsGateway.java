public interface SmsGateway {
  void send(String phone, String text) throws GatewayException;
}
