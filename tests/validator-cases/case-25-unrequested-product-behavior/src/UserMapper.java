public final class UserMapper {
  private UserMapper() {}
  public static UserView toView(User user) { return new UserView(user.id(), user.name()); }
}
