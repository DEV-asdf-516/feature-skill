public final class MaskingUtil {
  private MaskingUtil() {}
  public static String maskPhone(String phone) {
    return maskPhone(phone, 3);
  }
  public static String maskPhone(String phone, int visiblePrefix) {
    if (phone.length() < visiblePrefix + 5) return phone;
    return phone.substring(0, visiblePrefix) + "****" + phone.substring(visiblePrefix + 4);
  }
}
