public final class MaskingUtil {
  private MaskingUtil() {}
  public static String maskPhone(String phone) {
    return maskPhone(phone, '*');
  }
  public static String maskPhone(String phone, char mask) {
    if (phone.length() < 8) return phone;
    return phone.substring(0, 3) + String.valueOf(mask).repeat(4) + phone.substring(7);
  }
}
