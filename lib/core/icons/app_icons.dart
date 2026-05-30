// ignore_for_file: constant_identifier_names

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Centralized icon facade for the whole project.
///
/// Все иконки приложения идут только через `AppIcons.X` и физически
/// отрисовываются Lucide-семейством (тонкий stroke 1.5px, одинаковая
/// геометрия). Это убирает разнобой `_outlined` / `_rounded` /
/// `_sharp` Material-вариантов и даёт единый «модерн-финтех» стиль.
///
/// Имена полей сохраняют исходные snake_case Material-имена, чтобы
/// поиск/замена и навигация в IDE оставались привычными.
class AppIcons {
  AppIcons._();

  // ── Time / clock ──
  static const IconData access_time = LucideIcons.clock;
  static const IconData schedule = LucideIcons.clock;
  static const IconData timer = LucideIcons.timer;
  static const IconData pending_actions = LucideIcons.clock;
  static const IconData history = LucideIcons.history;
  static const IconData history_toggle_off = LucideIcons.history;
  static const IconData lock_clock = LucideIcons.lock;
  static const IconData calendar_today = LucideIcons.calendar;
  static const IconData date_range = LucideIcons.calendarRange;

  // ── Money / finance ──
  static const IconData account_balance = LucideIcons.landmark;
  static const IconData account_balance_wallet = LucideIcons.wallet;
  static const IconData attach_money = LucideIcons.dollarSign;
  static const IconData credit_card = LucideIcons.creditCard;
  static const IconData more_horiz = LucideIcons.ellipsis;
  static const IconData sort = LucideIcons.arrowDownUp;
  static const IconData currency_exchange = LucideIcons.arrowLeftRight;
  static const IconData payments = LucideIcons.banknote;
  static const IconData percent = LucideIcons.percent;
  static const IconData receipt_long = LucideIcons.receipt;
  static const IconData point_of_sale = LucideIcons.receiptText;
  static const IconData calculate = LucideIcons.calculator;
  static const IconData shopping_cart = LucideIcons.shoppingCart;
  static const IconData local_shipping = LucideIcons.truck;

  // ── Arrows / navigation ──
  static const IconData arrow_back = LucideIcons.arrowLeft;
  static const IconData arrow_forward = LucideIcons.arrowRight;
  static const IconData arrow_upward = LucideIcons.arrowUp;
  static const IconData arrow_downward = LucideIcons.arrowDown;
  static const IconData arrow_drop_down = LucideIcons.chevronDown;
  static const IconData chevron_left = LucideIcons.chevronLeft;
  static const IconData chevron_right = LucideIcons.chevronRight;
  static const IconData expand_less = LucideIcons.chevronUp;
  static const IconData expand_more = LucideIcons.chevronDown;
  static const IconData north_east = LucideIcons.arrowUpRight;
  static const IconData south_west = LucideIcons.arrowDownLeft;
  static const IconData swap_horiz = LucideIcons.arrowLeftRight;
  static const IconData swap_vert = LucideIcons.arrowUpDown;
  static const IconData sort_by_alpha = LucideIcons.arrowDownAZ;

  // ── Add / remove / edit ──
  static const IconData add = LucideIcons.plus;
  static const IconData add_box = LucideIcons.squarePlus;
  static const IconData add_business = LucideIcons.building2;
  static const IconData add_circle_outline = LucideIcons.circlePlus;
  static const IconData add_link = LucideIcons.link;
  static const IconData remove = LucideIcons.minus;
  static const IconData remove_circle_outline = LucideIcons.circleMinus;
  static const IconData delete = LucideIcons.trash2;
  static const IconData delete_forever = LucideIcons.trash2;
  static const IconData delete_outline = LucideIcons.trash2;
  static const IconData edit = LucideIcons.pencil;
  static const IconData edit_note = LucideIcons.pencil;
  static const IconData save = LucideIcons.save;
  static const IconData copy = LucideIcons.copy;

  // ── Status / feedback ──
  static const IconData check = LucideIcons.check;
  static const IconData check_circle = LucideIcons.circleCheck;
  static const IconData check_circle_outline = LucideIcons.circleCheck;
  static const IconData task_alt = LucideIcons.circleCheck;
  static const IconData fact_check = LucideIcons.clipboardCheck;
  static const IconData verified_user = LucideIcons.userCheck;
  static const IconData clear = LucideIcons.x;
  static const IconData clear_all = LucideIcons.x;
  static const IconData close = LucideIcons.x;
  static const IconData cancel = LucideIcons.circleX;
  static const IconData block = LucideIcons.ban;
  static const IconData do_not_disturb = LucideIcons.ban;
  static const IconData do_disturb_alt = LucideIcons.ban;
  static const IconData warning_amber = LucideIcons.triangleAlert;
  static const IconData error_outline = LucideIcons.circleAlert;
  static const IconData info_outline = LucideIcons.info;
  static const IconData rocket_launch = LucideIcons.rocket;
  static const IconData star = LucideIcons.star;

  // ── People / accounts ──
  static const IconData person_outline = LucideIcons.user;
  static const IconData person_add = LucideIcons.userPlus;
  static const IconData person_off = LucideIcons.userX;
  static const IconData person_search = LucideIcons.userSearch;
  static const IconData people = LucideIcons.users;
  static const IconData people_outline = LucideIcons.users;
  static const IconData contacts = LucideIcons.contact;
  static const IconData manage_accounts = LucideIcons.userCog;
  static const IconData supervisor_account = LucideIcons.shieldUser;
  static const IconData admin_panel_settings = LucideIcons.shieldUser;
  static const IconData security = LucideIcons.shield;
  static const IconData shield = LucideIcons.shield;
  static const IconData fingerprint = LucideIcons.fingerprintPattern;

  // ── Communication ──
  static const IconData mail_outline = LucideIcons.mail;
  static const IconData email = LucideIcons.mail;
  static const IconData phone = LucideIcons.phone;
  static const IconData call_received = LucideIcons.phoneIncoming;
  static const IconData chat_bubble_outline = LucideIcons.messageCircle;
  static const IconData send = LucideIcons.send;
  static const IconData outbox = LucideIcons.send;
  static const IconData inbox = LucideIcons.inbox;
  static const IconData notifications = LucideIcons.bell;
  static const IconData notifications_active = LucideIcons.bellRing;
  static const IconData notifications_none = LucideIcons.bell;

  // ── Files / docs ──
  static const IconData description = LucideIcons.fileText;
  static const IconData note = LucideIcons.stickyNote;
  static const IconData notes = LucideIcons.fileText;
  static const IconData summarize = LucideIcons.fileText;
  static const IconData download = LucideIcons.download;
  static const IconData file_download = LucideIcons.download;
  static const IconData upload_file = LucideIcons.upload;
  static const IconData archive = LucideIcons.archive;
  static const IconData unarchive = LucideIcons.archiveRestore;
  static const IconData label_outline = LucideIcons.tag;
  static const IconData flag = LucideIcons.flag;
  static const IconData place = LucideIcons.mapPin;

  // ── UI / layout ──
  static const IconData menu = LucideIcons.menu;
  static const IconData dashboard = LucideIcons.layoutDashboard;
  static const IconData category = LucideIcons.layoutGrid;
  static const IconData grid_view = LucideIcons.layoutGrid;
  static const IconData view_column = LucideIcons.columns2;
  static const IconData filter_list = LucideIcons.funnel;
  static const IconData filter_alt_off = LucideIcons.funnelX;
  static const IconData tune = LucideIcons.slidersHorizontal;
  static const IconData search = LucideIcons.search;
  static const IconData visibility = LucideIcons.eye;
  static const IconData visibility_off = LucideIcons.eyeOff;
  static const IconData select_all = LucideIcons.squareCheck;
  static const IconData deselect = LucideIcons.square;
  static const IconData touch_app = LucideIcons.mousePointerClick;

  // ── Charts / analytics ──
  static const IconData analytics = LucideIcons.chartBar;
  static const IconData insights = LucideIcons.chartBar;
  static const IconData query_stats = LucideIcons.trendingUp;
  static const IconData show_chart = LucideIcons.trendingUp;
  static const IconData trending_up = LucideIcons.trendingUp;
  static const IconData pie_chart = LucideIcons.chartPie;
  static const IconData bolt = LucideIcons.zap;

  // ── System / settings ──
  static const IconData settings = LucideIcons.settings;
  static const IconData refresh = LucideIcons.refreshCw;
  static const IconData logout = LucideIcons.logOut;
  static const IconData lock_outline = LucideIcons.lock;
  static const IconData link_off = LucideIcons.link2Off;
  static const IconData cloud_off = LucideIcons.cloudOff;
  static const IconData language = LucideIcons.globe;
  static const IconData qr_code = LucideIcons.qrCode;
  static const IconData code = LucideIcons.code;
  static const IconData power_off = LucideIcons.power;

  // ── Devices / business ──
  static const IconData business = LucideIcons.building2;
  static const IconData desktop_windows = LucideIcons.monitor;
  static const IconData smartphone = LucideIcons.smartphone;
  static const IconData devices_other = LucideIcons.monitorSmartphone;
  static const IconData account_tree = LucideIcons.gitBranch;
  static const IconData alt_route = LucideIcons.gitFork;
  static const IconData fiber_manual_record = LucideIcons.dot;
}
