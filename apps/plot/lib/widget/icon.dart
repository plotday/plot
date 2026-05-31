import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class PlotIcon {
  // UI
  static const left = FontAwesomeIcons.chevronLeft;
  static const right = FontAwesomeIcons.chevronRight;
  static const up = FontAwesomeIcons.anglesUp;
  static const down = FontAwesomeIcons.anglesDown;
  static const verticalExpand = FontAwesomeIcons.anglesUpDown;
  static const addActivity = FontAwesomeIcons.arrowUp;
  static const pipe = FontAwesomeIcons.pipe;
  static const schedule = FontAwesomeIcons.calendar;
  static const add = FontAwesomeIcons.plus;
  static const addNote = FontAwesomeIcons.penToSquare;
  static const edit = FontAwesomeIcons.pen;
  static const remove = FontAwesomeIcons.minus;
  static const startOfDay = FontAwesomeIcons.sunHaze;
  // Focuses (formerly nested "priorities") use the bullseye-pointer icon
  // consistently. `priorities` is the flat-list nav icon (no longer a tree).
  static const priority = FontAwesomeIcons.bullseyePointer;
  static const priorities = FontAwesomeIcons.list;

  /// The fixed Inbox tile (unfiled threads) and the Everything feed (the
  /// unscoped feed across the Inbox and every focus).
  static const inbox = FontAwesomeIcons.inbox;
  static const inboxes = FontAwesomeIcons.inboxes;

  /// The default icon for a focus when none is chosen.
  static const focusDefault = FontAwesomeIcons.bullseyePointer;

  /// Curated set of icons a user can pick for a focus, keyed by a stable
  /// string stored in `priority.icon`. The key (not the glyph) is persisted,
  /// so renaming a glyph never changes stored data. Resolve with [focusIcon].
  static const Map<String, IconData> focusIcons = {
    'bullseyePointer': FontAwesomeIcons.bullseyePointer,
    'user': FontAwesomeIcons.user,
    'userGroup': FontAwesomeIcons.userGroup,
    'userMagnifyingGlass': FontAwesomeIcons.userMagnifyingGlass,
    'family': FontAwesomeIcons.family,
    'briefcase': FontAwesomeIcons.briefcase,
    'bookOpen': FontAwesomeIcons.bookOpen,
    'listCheck': FontAwesomeIcons.listCheck,
    'piggyBank': FontAwesomeIcons.piggyBank,
    'house': FontAwesomeIcons.house,
    'code': FontAwesomeIcons.code,
    'conveyorBelt': FontAwesomeIcons.conveyorBelt,
    'receipt': FontAwesomeIcons.receipt,
    'bullhorn': FontAwesomeIcons.bullhorn,
    'handshake': FontAwesomeIcons.handshake,
    'scaleBalanced': FontAwesomeIcons.scaleBalanced,
    'rocket': FontAwesomeIcons.rocket,
    'chartLine': FontAwesomeIcons.chartLine,
    'building': FontAwesomeIcons.building,
    'calendarDays': FontAwesomeIcons.calendarDays,
    'lightbulb': FontAwesomeIcons.lightbulb,
    'heart': FontAwesomeIcons.heart,
    'flask': FontAwesomeIcons.flask,
    'paintbrush': FontAwesomeIcons.paintbrush,
    'penNib': FontAwesomeIcons.penNib,
    'dumbbell': FontAwesomeIcons.dumbbell,
    'graduationCap': FontAwesomeIcons.graduationCap,
    'cartShopping': FontAwesomeIcons.cartShopping,
    'seedling': FontAwesomeIcons.seedling,
    'balloons': FontAwesomeIcons.balloons,
    'music': FontAwesomeIcons.music,
    'microphoneStand': FontAwesomeIcons.microphoneStand,
    'bowlHot': FontAwesomeIcons.bowlHot,
    'plane': FontAwesomeIcons.plane,
    'mountain': FontAwesomeIcons.mountain,
    'globe': FontAwesomeIcons.globe,
  };

  /// Resolves a stored focus icon key to its glyph, falling back to the
  /// default focus icon for null/unknown keys.
  static IconData focusIcon(String? key) => focusIcons[key] ?? focusDefault;

  /// Human-friendly labels for the curated focus icons, keyed identically to
  /// [focusIcons]. Labels are intentionally suggestive of what a focus using
  /// the icon might represent or how it might be applied (e.g. "Reading"
  /// rather than "Open book", "Team" rather than "Users group") so they read
  /// as focus categories in the picker rather than literal glyph names.
  static const Map<String, String> focusIconLabels = {
    'receipt': 'Admin',
    'balloons': 'Event',
    'bullseyePointer': 'Goal',
    'briefcase': 'Work',
    'userGroup': 'Team',
    'bookOpen': 'Reading',
    'userMagnifyingGlass': 'Hiring',
    'family': 'Family',
    'conveyorBelt': 'Operations',
    'piggyBank': 'Finances',
    'house': 'Home',
    'user': 'Personal',
    'code': 'Engineering',
    'rocket': 'Launch',
    'flask': 'Research',
    'paintbrush': 'Design',
    'penNib': 'Writing',
    'chartLine': 'Analytics',
    'calendarDays': 'Planning',
    'listCheck': 'Tasks',
    'lightbulb': 'Ideas',
    'heart': 'Wellness',
    'dumbbell': 'Fitness',
    'graduationCap': 'Learning',
    'plane': 'Travel',
    'cartShopping': 'Shopping',
    'handshake': 'Partnerships',
    'scaleBalanced': 'Legal',
    'building': 'Company',
    'bullhorn': 'Marketing',
    'seedling': 'Growth',
    'music': 'Music',
    'microphoneStand': 'Recording',
    'bowlHot': 'Food',
    'mountain': 'Challenge',
    'globe': 'World',
  };

  /// The display label for a focus icon [key], falling back to a humanised
  /// version of the key ('userGroup' -> 'User group') for any icon not present
  /// in [focusIconLabels].
  static String focusIconLabel(String key) =>
      focusIconLabels[key] ?? _humanizeIconKey(key);

  /// Humanises a focus-icon key: 'userGroup' -> 'User group'. Used as a
  /// fallback for keys missing from [focusIconLabels].
  static String _humanizeIconKey(String key) {
    if (key.isEmpty) return key;
    final buf = StringBuffer();
    for (var i = 0; i < key.length; i++) {
      final c = key[i];
      final isUpper = c.toUpperCase() == c && c.toLowerCase() != c;
      if (i == 0) {
        buf.write(c.toUpperCase());
      } else if (isUpper) {
        buf
          ..write(' ')
          ..write(c.toLowerCase());
      } else {
        buf.write(c);
      }
    }
    return buf.toString();
  }

  static const activity = FontAwesomeIcons.listCheck;
  static const open = FontAwesomeIcons.arrowRight;
  static const menu = FontAwesomeIcons.ellipsisVertical;
  static const more = FontAwesomeIcons.ellipsis;
  static const hamburgerMenu = FontAwesomeIcons.bars;
  static const close = FontAwesomeIcons.xmark;
  static const back = FontAwesomeIcons.arrowLeft;
  static const settings = FontAwesomeIcons.gear;
  static const account = FontAwesomeIcons.bars;
  static const event = FontAwesomeIcons.calendar;
  static const signOut = FontAwesomeIcons.rightFromBracket;
  static const sync = FontAwesomeIcons.arrowsRotate;
  static const filter = FontAwesomeIcons.filter;
  static const move = FontAwesomeIcons.arrowUTurnUpRight;
  static const sidebarOpen = FontAwesomeIcons.arrowRightFromLine;
  static const sidebarClose = FontAwesomeIcons.arrowLeftToLine;
  static const search = FontAwesomeIcons.magnifyingGlass;
  static const pin = FontAwesomeIcons.thumbtackAngle;
  static const unpin = FontAwesomeIcons.thumbtackAngleSlash;
  static const next = FontAwesomeIcons.arrowDownToLine;
  static const previous = FontAwesomeIcons.arrowUpToLine;
  static const note = FontAwesomeIcons.note;
  static const notes = FontAwesomeIcons.notes;
  static const reschedule = FontAwesomeIcons.calendarPen;
  static const calendarPlus = FontAwesomeIcons.calendarPlus;
  static const calendarXmark = FontAwesomeIcons.calendarXmark;
  static const calendarCheck = FontAwesomeIcons.calendarCheck;
  static const save = FontAwesomeIcons.check;
  static const share = FontAwesomeIcons.userPlus;
  static const shared = FontAwesomeIcons.users;
  static const user = FontAwesomeIcons.user;
  static const users = FontAwesomeIcons.users;
  static const private = FontAwesomeIcons.usersSlash;
  static const buildingLock = FontAwesomeIcons.buildingLock;
  static const buildingUser = FontAwesomeIcons.buildingUser;
  static const offline = FontAwesomeIcons.wifiSlash;
  static const notification = FontAwesomeIcons.bellRing;
  static const agenda = FontAwesomeIcons.calendarStar;
  static const message = FontAwesomeIcons.message;
  static const messages = FontAwesomeIcons.messages;
  static const on = FontAwesomeIcons.solidToggleOn;
  static const off = FontAwesomeIcons.solidToggleOff;

  // Task icons
  static const selfTask = FontAwesomeIcons.circlePlus;
  static const selfTaskTodo = FontAwesomeIcons.circle;
  static const selfTaskDone = FontAwesomeIcons.check;
  static const selfTaskHover = FontAwesomeIcons.circleCheck;
  static const selfTaskDoneHover = FontAwesomeIcons.circlePlus;
  static const othersTask = FontAwesomeIcons.circleUser;
  static const othersTaskDone = FontAwesomeIcons.circleUserCircleCheck;
  static const assignAdd = FontAwesomeIcons.circleUserCirclePlus;
  static const assignRemove = FontAwesomeIcons.circleUserCircleXmark;
  static const shareAdd = FontAwesomeIcons.userPlus;
  static const shareRemove = FontAwesomeIcons.userXmark;
  static const doneAll = FontAwesomeIcons.checkDouble;

  // Tags
  static const todo = FontAwesomeIcons.play;
  static const todoFilled = FontAwesomeIcons.solidPlay;
  static const addTodo = FontAwesomeIcons.circlePlus;
  static const comment = FontAwesomeIcons.comment;
  static const clipboardCheck = FontAwesomeIcons.clipboardCheck;
  static const bookOpenLines = FontAwesomeIcons.bookOpenLines;
  static const finish = FontAwesomeIcons.stop;
  static const someday = FontAwesomeIcons.circleMoon;
  static const later = FontAwesomeIcons.clock;
  static const alarmClock = FontAwesomeIcons.alarmClock;
  static const stopwatch = FontAwesomeIcons.stopwatch;
  static const done = FontAwesomeIcons.check;
  static const other = FontAwesomeIcons.circleUser;
  static const otherDone = FontAwesomeIcons.check;
  static const pinned = FontAwesomeIcons.thumbtackAngle;
  static const archived = FontAwesomeIcons.boxArchive;
  static const broom = FontAwesomeIcons.broomWide;
  static const urgent = FontAwesomeIcons.sirenOn;
  static const goal = FontAwesomeIcons.bullseyePointer;
  static const decision = FontAwesomeIcons.signsPost;
  static const yes = FontAwesomeIcons.thumbsUp;
  static const no = FontAwesomeIcons.thumbsDown;
  static const volunteer = FontAwesomeIcons.hand;
  static const celebration = FontAwesomeIcons.partyHorn;
  static const waiting = FontAwesomeIcons.hourglassHalf;
  static const blocked = FontAwesomeIcons.octagonXmark;
  static const warning = FontAwesomeIcons.triangleExclamation;
  static const twist = FontAwesomeIcons.wavesSine;
  static const connection = FontAwesomeIcons.plug;
  static const plugCircleXmark = FontAwesomeIcons.plugCircleXmark;
  static const plugCircleExclamation = FontAwesomeIcons.plugCircleExclamation;
  static const plugCircleBolt = FontAwesomeIcons.plugCircleBolt;
  static const plugCirclePlus = FontAwesomeIcons.plugCirclePlus;
  static const star = FontAwesomeIcons.star;
  static const idea = FontAwesomeIcons.lightbulb;
  static const unread = FontAwesomeIcons.messageDot;
  static const attachment = FontAwesomeIcons.paperclip;
  static const download = FontAwesomeIcons.arrowDownToLine;
  static const camera = FontAwesomeIcons.camera;
  static const link = FontAwesomeIcons.link;
  static const fire = FontAwesomeIcons.fire;
  static const totally = FontAwesomeIcons.hundredPoints;
  static const looking = FontAwesomeIcons.eyes;
  static const heart = FontAwesomeIcons.heart;
  static const gettingStarted = FontAwesomeIcons.play;
  static const code = FontAwesomeIcons.hammer;
  static const help = FontAwesomeIcons.commentsQuestion;
  static const rocket = FontAwesomeIcons.rocket;
  static const sparkles = FontAwesomeIcons.sparkles;
  static const thanks = FontAwesomeIcons.handsPraying;
  static const praise = FontAwesomeIcons.handsClapping;
  static const wave = FontAwesomeIcons.handWave;
  static const question = FontAwesomeIcons.commentsQuestion;
  static const flag = FontAwesomeIcons.flag;
  static const thinking = FontAwesomeIcons.faceThinking;
  static const remember = FontAwesomeIcons.handPointRibbon;
  static const agreed = FontAwesomeIcons.handshake;
  static const send = FontAwesomeIcons.paperPlane;
  static const noted = FontAwesomeIcons.noteSticky;

  // Emotions
  static const smile = FontAwesomeIcons.faceSmileBeam;
  static const cool = FontAwesomeIcons.faceSunglasses;
  static const heartEyes = FontAwesomeIcons.faceGrinHearts;
  static const cry = FontAwesomeIcons.faceSadTear;
  static const laugh = FontAwesomeIcons.faceLaughBeam;
  static const relieved = FontAwesomeIcons.faceRelieved;
  static const surprised = FontAwesomeIcons.faceAstonished;
  static const confused = FontAwesomeIcons.faceConfused;
  static const dismayed = FontAwesomeIcons.faceAnguished;

  // RSVPs (avatar/people variants)
  static const attend = FontAwesomeIcons.userCheck;
  static const skip = FontAwesomeIcons.userXmark;
  static const undecided = FontAwesomeIcons.userQuestion;

  // RSVP marks — used by the RSVP chip, picker, and details popover.
  // Clean bare marks; undecided is a quiet dash, not a question mark.
  static const rsvpGoing = FontAwesomeIcons.check;
  static const rsvpDeclined = FontAwesomeIcons.xmark;
  static const rsvpUndecided = FontAwesomeIcons.minus;

  // Thread sub-types
  static const action = FontAwesomeIcons.clipboardListCheck;
  static const bullhorn = FontAwesomeIcons.bullhorn;

  // Associations
  static const associated = FontAwesomeIcons.arrowTurnDownRight;

  // Conferencing
  static const video = FontAwesomeIcons.video;

  // Focus / agenda
  static const arrowsToDot = FontAwesomeIcons.arrowsToDot;
  static const location = FontAwesomeIcons.locationDot;
}
