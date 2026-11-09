public class UserService {
  private final UserRepository repo;
  public UserService(UserRepository repo) { this.repo = repo; }

  public UserView get(long id) { return UserMapper.toView(findOrThrow(id)); }

  public void rename(long id, String name) {
    findOrThrow(id);
    repo.updateName(id, name);
  }

  private User findOrThrow(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("user " + id));
  }
}
