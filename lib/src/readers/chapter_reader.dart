import '../ref_entities/epub_book_ref.dart';
import '../ref_entities/epub_chapter_ref.dart';
import '../ref_entities/epub_text_content_file_ref.dart';
import '../schema/navigation/epub_navigation_point.dart';

class ChapterReader {
  static List<EpubChapterRef> getChapters(EpubBookRef bookRef) {
    if (bookRef.Schema!.Navigation == null) {
      return <EpubChapterRef>[];
    }
    return getChaptersImpl(
        bookRef, bookRef.Schema!.Navigation!.NavMap!.Points!);
  }

  /// Returns chapters based on the spine order, ignoring NCX navigation.
  /// Useful for EPUBs with incomplete or minimal NCX navigation files.
  static Future<List<EpubChapterRef>> getChaptersFromSpine(EpubBookRef bookRef) async {
    var result = <EpubChapterRef>[];
    var spine = bookRef.Schema!.Package!.Spine;
    var manifest = bookRef.Schema!.Package!.Manifest;
    if (spine == null || manifest == null) {
      return result;
    }

    // First pass: build chapters and extract <title> elements
    var htmlContents = <String>[];
    for (var spineItem in spine.Items!) {
      var manifestItem = manifest.Items!.cast().firstWhere(
            (item) => item.Id == spineItem.IdRef,
            orElse: () => null,
          );
      if (manifestItem == null) continue;

      var href = manifestItem.Href as String?;
      if (href == null) continue;

      // Prepend content directory path if needed
      var contentDirectoryPath = bookRef.Schema!.ContentDirectoryPath;
      var contentFileName = contentDirectoryPath != null && contentDirectoryPath.isNotEmpty
          ? '$contentDirectoryPath/$href'
          : href;

      EpubTextContentFileRef? htmlContentFileRef;
      // Try to find the HTML content file
      if (bookRef.Content!.Html!.containsKey(contentFileName)) {
        htmlContentFileRef = bookRef.Content!.Html![contentFileName];
      } else if (bookRef.Content!.Html!.containsKey(href)) {
        htmlContentFileRef = bookRef.Content!.Html![href];
        contentFileName = href;
      } else {
        // Skip non-HTML content (like NCX files)
        continue;
      }

      var chapterRef = EpubChapterRef(htmlContentFileRef);
      chapterRef.ContentFileName = contentFileName;
      chapterRef.SubChapters = <EpubChapterRef>[];

      // Read HTML content and extract <title>
      String? html;
      try {
        html = await htmlContentFileRef?.readContentAsText();
      } catch (_) {}
      htmlContents.add(html ?? '');

      chapterRef.Title = _extractTitle(html) ?? manifestItem.Id as String;
      result.add(chapterRef);
    }

    // If 4+ chapters and more than half have the same title, fall back to first <h> tag
    if (result.length >= 4) {
      var titleCounts = <String?, int>{};
      for (var c in result) {
        titleCounts[c.Title] = (titleCounts[c.Title] ?? 0) + 1;
      }
      var maxCount = titleCounts.values.reduce((a, b) => a > b ? a : b);
      if (maxCount > result.length / 2) {
        for (var i = 0; i < result.length; i++) {
          var hTitle = _extractFirstHeading(htmlContents[i]);
          if (hTitle != null) {
            result[i].Title = hTitle;
          }
        }
      }
    }

    return result;
  }

  static final _titleRegex = RegExp(r'<title[^>]*>([^<]*)</title>', caseSensitive: false);
  static final _headingRegex = RegExp(r'<h[1-6][^>]*>(.*?)</h[1-6]>', caseSensitive: false, dotAll: true);
  static final _tagStripRegex = RegExp(r'<[^>]*>');

  static String? _extractTitle(String? html) {
    if (html == null) return null;
    var match = _titleRegex.firstMatch(html);
    if (match != null) {
      var title = match.group(1)?.trim();
      if (title != null && title.isNotEmpty) {
        return title;
      }
    }
    return null;
  }

  static String? _extractFirstHeading(String? html) {
    if (html == null) return null;
    var match = _headingRegex.firstMatch(html);
    if (match != null) {
      var hContent = match.group(1);
      if (hContent != null) {
        // Strip inner HTML tags and normalize whitespace
        var title = hContent.replaceAll(_tagStripRegex, '').replaceAll(RegExp(r'\s+'), ' ').trim();
        if (title.isNotEmpty) {
          return title;
        }
      }
    }
    return null;
  }

  static List<EpubChapterRef> getChaptersImpl(
      EpubBookRef bookRef, List<EpubNavigationPoint> navigationPoints) {
    var result = <EpubChapterRef>[];
    // navigationPoints.forEach((EpubNavigationPoint navigationPoint) {
    for (var navigationPoint in navigationPoints){
      String? contentFileName;
      String? anchor;
      if (navigationPoint.Content?.Source ==null) continue;
      var contentSourceAnchorCharIndex =
          navigationPoint.Content!.Source!.indexOf('#');
      if (contentSourceAnchorCharIndex == -1) {
        contentFileName = navigationPoint.Content!.Source;
        anchor = null;
      } else {
        contentFileName = navigationPoint.Content!.Source!
            .substring(0, contentSourceAnchorCharIndex);
        anchor = navigationPoint.Content!.Source!
            .substring(contentSourceAnchorCharIndex + 1);
      }
      contentFileName = Uri.decodeFull(contentFileName!);
      EpubTextContentFileRef? htmlContentFileRef;
      if (!bookRef.Content!.Html!.containsKey(contentFileName)) {
        throw Exception(
            'Incorrect EPUB manifest: item with href = \"$contentFileName\" is missing.');
      }

      htmlContentFileRef = bookRef.Content!.Html![contentFileName];
      var chapterRef = EpubChapterRef(htmlContentFileRef);
      chapterRef.ContentFileName = contentFileName;
      chapterRef.Anchor = anchor;
      chapterRef.Title = navigationPoint.NavigationLabels!.first.Text;
      chapterRef.SubChapters =
          getChaptersImpl(bookRef, navigationPoint.ChildNavigationPoints!);
      if(chapterRef.ContentFileName!.contains('_split_')) {
        var fileNamePart = chapterRef.ContentFileName!.split('_split_')[0];
        for (var fileName in bookRef.Content!.Html!.keys) {
          if(fileName.contains(fileNamePart)) {
            if (fileName == contentFileName) {
              continue;
            }
            chapterRef.otherTextContentFileRefs.add(bookRef.Content!.Html![fileName]!);
            chapterRef.OtherContentFileNames.add(fileName);
          }
        }
      }

      result.add(chapterRef);
    };
    return result;
  }
}
