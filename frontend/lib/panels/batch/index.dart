import '../panel.dart';
import 'cronjob_panel.dart';
import 'job_panel.dart';

/// Panels owned by the "batch" feature area. Registered in ../registry.dart.
final List<ResourcePanel> batchPanels = [const JobPanel(), const CronJobPanel()];
