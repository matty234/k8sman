/// The inspectors' shared building blocks, in the pod inspector's style:
///
/// - [InspectorHeader]: a headline with a mark, a detail line, an optional
///   progress bar, large [InspectorFigure]s, [Insight]s, actions and facts.
/// - [InsightList] / [InsightLine]: a severity bar, a title, a muted body
///   and an optional action.
/// - [InspectorSection]: a collapsible section with a [SectionSummary],
///   remembered per session in [SectionMemory].
/// - [InspectorRow]: a compact row (dot, title, subtitle, trailing,
///   actions on hover, details on demand); [PodRows] for pods, problems
///   first.
/// - [QuietGroup], [TrimmedList], [HoverCopy], [OwnerLine] / [ownerFact],
///   and [SharedFetch] for a fetch a header and a section share.
library;

export 'header.dart';
export 'insights.dart';
export 'owner_line.dart';
export 'parts.dart';
export 'pod_rows.dart';
export 'rows.dart';
export 'section.dart';
export 'shared_fetch.dart';
