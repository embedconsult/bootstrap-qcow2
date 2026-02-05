# String helpers.
class String
  # Return a lowercase, underscore-separated version of the string.
  def underscore : String
    gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
      .gsub(/([a-z\\d])([A-Z])/, "\\1_\\2")
      .tr("-", "_")
      .downcase
  end
end
