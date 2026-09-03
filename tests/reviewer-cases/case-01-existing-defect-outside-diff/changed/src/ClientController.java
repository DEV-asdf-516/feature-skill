public class ClientController {
  private final ClientService service;
  public ClientController(ClientService service) { this.service = service; }

  @GetMapping("/clients/{id}")
  public Client get(@PathVariable long id) { return service.get(id); }

  @GetMapping("/clients/{id}/summary")
  public ClientSummary summary(@PathVariable long id) { return service.summary(id); }
}
