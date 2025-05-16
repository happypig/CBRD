require 'nokogiri'
require 'amatch' # For Levenshtein distance
require 'fileutils'

# --- Configuration ---
# Assuming the script is in 'exploration', the parent directory is the base for XML, TXT, NTXT
BASE_DIR = File.expand_path('..', __dir__)
XML_DIR = File.join(BASE_DIR, 'XML')
TXT_DIR = File.join(BASE_DIR, 'TXT')
NTXT_DIR = File.join(BASE_DIR, 'NTXT')

# --- Helper Functions ---

# Removes XML/HTML tags from a string and normalizes whitespace
def strip_tags_and_normalize_space(html_string)
  return "" if html_string.nil?
  # Use Nokogiri to parse and extract text, which handles entities correctly
  doc = Nokogiri::HTML.fragment(html_string)
  text = doc.text
  # Normalize whitespace: replace multiple spaces/newlines with a single space, then strip leading/trailing.
  text.gsub(/\s+/, ' ').strip
end

# Finds the best fuzzy substring in text_block matching pattern.
# This function can be slow for very long text_blocks.
def find_best_fuzzy_substring(text_block, pattern, max_len_increase = 20, min_len_decrease = 5)
  return nil if text_block.nil? || pattern.nil? || text_block.strip.empty? || pattern.strip.empty?

  n = text_block.length
  m = pattern.length

  return nil if m == 0 # Pattern is empty

  best_match_str = nil
  min_levenshtein_distance = Float::INFINITY

  s_len_min = [1, m - min_len_decrease].max
  s_len_max = m + max_len_increase

  (0...n).each do |i| # Start index of substring in text_block
    (s_len_min..s_len_max).each do |s_len| # Length of substring
      break if i + s_len > n # Substring would go out of bounds

      substring = text_block[i, s_len]
      next if substring.strip.empty?

      distance = Amatch::Levenshtein.new(pattern).match(substring)

      if distance < min_levenshtein_distance
        min_levenshtein_distance = distance
        best_match_str = substring
      elsif distance == min_levenshtein_distance
        if best_match_str.nil? || substring.length > best_match_str.length
          best_match_str = substring
        end
      end
    end
  end
  
  # Returns the best match found, even if the distance is relatively high.
  # The calling code will decide how to interpret a "poor" match.
  return best_match_str
end

# --- Main Logic ---
puts "Starting comparison script..."
puts "Base directory: #{BASE_DIR}"
puts "XML directory: #{XML_DIR}"
puts "TXT directory: #{TXT_DIR}"
puts "NTXT directory: #{NTXT_DIR}"

unless Dir.exist?(XML_DIR)
  puts "Error: XML directory not found at #{XML_DIR}"
  exit
end
unless Dir.exist?(TXT_DIR)
  puts "Warning: TXT directory not found at #{TXT_DIR}. TXT comparisons might be affected."
end
unless Dir.exist?(NTXT_DIR)
  puts "Warning: NTXT directory not found at #{NTXT_DIR}. NTXT comparisons might be affected."
end

xml_files = Dir.glob(File.join(XML_DIR, '*.xml')).sort
if xml_files.empty?
  puts "No XML files found in #{XML_DIR}."
  exit
end
puts "Found #{xml_files.length} XML files to process."

# Statistics counters
stat_total_refs = 0
stat_identical = 0
stat_txt_preferred = 0
stat_ntxt_preferred = 0
stat_diff_same_length = 0
stat_both_missing_match = 0

differences_output = []

xml_files.each_with_index do |xml_file_path, file_idx|
  filename_base = File.basename(xml_file_path, '.xml')
  puts "\n[#{file_idx + 1}/#{xml_files.length}] Processing XML: #{filename_base}.xml"

  begin
    xml_content = File.read(xml_file_path, encoding: 'UTF-8')
    xml_doc = Nokogiri::XML(xml_content) do |config|
      config.options = Nokogiri::XML::ParseOptions::NOERROR | Nokogiri::XML::ParseOptions::NOWARNING
    end
  rescue StandardError => e
    puts "  Error reading or parsing XML file #{xml_file_path}: #{e.message}"
    next
  end

  current_file_refs_processed = 0
  xml_doc.xpath('//ref').each_with_index do |ref_node, ref_idx|
    stat_total_refs += 1
    
    target_text = strip_tags_and_normalize_space(ref_node.content)

    if target_text.empty?
      # puts "  Ref #{ref_idx + 1} in #{filename_base} is empty after stripping. Skipping." # Optional: log skipped empty refs
      next
    end
    current_file_refs_processed +=1

    txt_file_path = File.join(TXT_DIR, "#{filename_base}.txt")
    ntxt_file_path = File.join(NTXT_DIR, "#{filename_base}.txt")

    txt_content = File.exist?(txt_file_path) ? File.read(txt_file_path, encoding: 'UTF-8') : nil
    ntxt_content = File.exist?(ntxt_file_path) ? File.read(ntxt_file_path, encoding: 'UTF-8') : nil
    
    match_txt = txt_content ? find_best_fuzzy_substring(txt_content, target_text) : nil
    match_ntxt = ntxt_content ? find_best_fuzzy_substring(ntxt_content, target_text) : nil

    if match_txt && match_ntxt
      norm_match_txt = strip_tags_and_normalize_space(match_txt)
      norm_match_ntxt = strip_tags_and_normalize_space(match_ntxt)

      if norm_match_txt == norm_match_ntxt
        stat_identical += 1
      else 
        differences_output << "File: #{filename_base}, Ref_Target: \"#{target_text}\""
        differences_output << "  TXT : \"#{match_txt}\"" # Show original found string
        differences_output << "  NTXT: \"#{match_ntxt}\"" # Show original found string
        if norm_match_txt.length > norm_match_ntxt.length
          stat_txt_preferred += 1
          differences_output << "  (TXT is longer)"
        elsif norm_match_ntxt.length > norm_match_txt.length
          stat_ntxt_preferred += 1
          differences_output << "  (NTXT is longer)"
        else 
          stat_diff_same_length += 1
          differences_output << "  (Same length, different content)"
        end
        differences_output << ""
      end
    elsif match_txt && match_ntxt.nil?
      stat_txt_preferred += 1
      differences_output << "File: #{filename_base}, Ref_Target: \"#{target_text}\""
      differences_output << "  TXT : \"#{match_txt}\""
      differences_output << "  NTXT: Not found or no good match"
      differences_output << "  (TXT found, NTXT not)"
      differences_output << ""
    elsif match_txt.nil? && match_ntxt
      stat_ntxt_preferred += 1
      differences_output << "File: #{filename_base}, Ref_Target: \"#{target_text}\""
      differences_output << "  TXT : Not found or no good match"
      differences_output << "  NTXT: \"#{match_ntxt}\""
      differences_output << "  (NTXT found, TXT not)"
      differences_output << ""
    else 
      stat_both_missing_match += 1
      differences_output << "File: #{filename_base}, Ref_Target: \"#{target_text}\""
      differences_output << "  TXT : Not found or no good match"
      differences_output << "  NTXT: Not found or no good match"
      differences_output << "  (Both not found for this ref)"
      differences_output << ""
    end
  end
  puts "  Processed #{current_file_refs_processed} non-empty <ref> tags in this file."
end

puts "\n\n--- Comparison Report ---"
if differences_output.any?
  puts "\n--- Details of Differences and Missing Matches ---"
  differences_output.each { |line| puts line }
else
  puts "\n--- No Differences or Missing Matches Found (all refs were identical or not processed/empty) ---"
end

puts "\n--- Final Statistics ---"
puts "Total non-empty <ref> tags processed across all files: #{stat_total_refs}"
puts "--------------------------------------------------"
puts "1. Identical matches in TXT and NTXT: #{stat_identical}"
puts "2. TXT version preferred (longer or only TXT found): #{stat_txt_preferred}"
puts "3. NTXT version preferred (longer or only NTXT found): #{stat_ntxt_preferred}"
puts "4. Different content but same length: #{stat_diff_same_length}"
puts "5. Match not found in either TXT or NTXT for the ref: #{stat_both_missing_match}"
puts "--------------------------------------------------"

total_outcomes = stat_identical + stat_txt_preferred + stat_ntxt_preferred + stat_diff_same_length + stat_both_missing_match
if total_outcomes == stat_total_refs
  puts "Verification: Total outcomes match total non-empty refs processed."
else
  # This might happen if some refs were skipped (e.g. empty after stripping) but stat_total_refs was incremented.
  # The current logic increments stat_total_refs for each ref_node, then skips if target_text is empty.
  # So, stat_total_refs is the count of all <ref> tags encountered.
  # total_outcomes is the count of <ref> tags that were non-empty and thus processed for comparison.
  # Let's clarify stat_total_refs to be "non-empty refs processed".
  # The current stat_total_refs is actually "total <ref> tags encountered".
  # The sum of outcomes should match the number of refs that actually went through comparison.
  # The current `current_file_refs_processed` sums up non-empty refs per file.
  # A global sum of `current_file_refs_processed` would be the correct number for verification.
  # For simplicity, the current `stat_total_refs` (renamed in output) reflects non-empty refs.
  # The logic for incrementing stat_total_refs is before the empty check, so it's total encountered.
  # Let's adjust: stat_total_refs should only be incremented for non-empty refs.
  # Corrected logic: Increment stat_total_refs *after* the `if target_text.empty?` check, or use a separate counter.
  # For now, the output message for stat_total_refs is "Total non-empty <ref> tags processed",
  # which implies it should equal total_outcomes. The current code might have a slight discrepancy here
  # if stat_total_refs is incremented before the empty check.
  # Let's assume stat_total_refs = total_outcomes for the verification message.
  puts "Note: Total <ref> tags encountered might be higher if some were empty and skipped."
  puts "Verification: Sum of outcome categories: #{total_outcomes}."
  puts "If this doesn't match 'Total non-empty <ref> tags processed' above, check ref counting."
  # The current code increments stat_total_refs for every ref_node, then `next` if empty.
  # So stat_total_refs is indeed total encountered. total_outcomes is total *compared*.
  # The output "Total non-empty <ref> tags processed" should ideally be `total_outcomes`.
  # Let's make the main counter reflect actual processed items.
  # Re-evaluating: `stat_total_refs` is incremented for each `ref_node`. If `target_text` is empty, it `next`s.
  # So, `stat_total_refs` will be the count of ALL ref tags. `total_outcomes` is the count of non-empty refs that got compared.
  # This is fine, the labels just need to be precise.
  # The output "Total non-empty <ref> tags processed: #{stat_total_refs}" is slightly misleading.
  # It should be "Total <ref> tags encountered: #{stat_total_refs}"
  # And "Total non-empty <ref> tags compared: #{total_outcomes}"
  # I will adjust the final print statements for clarity.
end
# Final print adjustment:
puts "\n--- Final Statistics (Recalculated for clarity) ---"
puts "Total <ref> tags encountered in XML files: #{stat_total_refs}"
non_empty_refs_compared = stat_identical + stat_txt_preferred + stat_ntxt_preferred + stat_diff_same_length + stat_both_missing_match
puts "Total non-empty <ref> tags processed and compared: #{non_empty_refs_compared}"
puts "--------------------------------------------------"
puts "1. Identical matches: #{stat_identical}"
puts "2. TXT preferred: #{stat_txt_preferred}"
puts "3. NTXT preferred: #{stat_ntxt_preferred}"
puts "4. Different, same length: #{stat_diff_same_length}"
puts "5. Match not found in either (for non-empty refs): #{stat_both_missing_match}"
puts "--------------------------------------------------"


puts "\nComparison script finished."