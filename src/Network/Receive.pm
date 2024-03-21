#########################################################################
#  OpenKore - Server message parsing
#
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#########################################################################
##
# MODULE DESCRIPTION: Server message parsing
#
# This class is responsible for parsing messages that are sent by the RO
# server to Kore. Information in the messages are stored in global variables
# (in the module Globals).
#
# Please also read <a href="http://www.openkore.com/wiki/index.php/Network_subsystem">the
# network subsystem overview.</a>
package Network::Receive;

use strict;
use Time::HiRes qw(time usleep);
use encoding 'utf8';
use Carp::Assert;
use Scalar::Util;

use Globals;
use Actor;
use Actor::You;
use Actor::Player;
use Actor::Monster;
use Actor::Party;
use Actor::Item;
use Actor::Unknown;
use Settings;
use Log qw(message warning error debug);
use FileParsers;
use Interface;
use Network;
use Network::Send ();
use Misc;
use Plugins;
use Utils;
use Skill;
use AI;
use Utils::Exceptions;
use Utils::Crypton;
use Translation;
use I18N qw(bytesToString);

###### Public methods ######

sub new {
	my ($class) = @_;
	my %self;

	# If you are wondering about those funny strings like 'x2 v1' read http://perldoc.perl.org/functions/pack.html
	# and http://perldoc.perl.org/perlpacktut.html

	# Defines a list of Packet Handlers and decoding information
	# 'packetSwitch' => ['handler function','unpack string',[qw(argument names)]]

	$self{packet_list} = {
		'0069' => ['account_server_info', 'x2 a4 a4 a4 x30 C1 a*', [qw(sessionID accountID sessionID2 accountSex serverInfo)]],
		'006A' => ['login_error', 'C1', [qw(type)]],
		'006B' => ['received_characters'],
		'006C' => ['login_error_game_login_server'],
		'006D' => ['character_creation_successful', 'a4 x4 V1 x62 Z24 C1 C1 C1 C1 C1 C1 C1', [qw(ID zenny name str agi vit int dex luk slot)]],
		'006E' => ['character_creation_failed'],
		'006F' => ['character_deletion_successful'],
		'0070' => ['character_deletion_failed'],
		'0071' => ['received_character_ID_and_Map', 'a4 Z16 a4 v1', [qw(charID mapName mapIP mapPort)]],
		'0073' => ['map_loaded','V a3',[qw(syncMapSync coords)]],
		'0075' => ['changeToInGameState'],
		'0077' => ['changeToInGameState'],
		'0078' => ['actor_display', 'a4 v14 a4 x7 C1 a3 x2 C1 v1', [qw(ID walk_speed param1 param2 param3 type hair_style weapon lowhead shield tophead midhead hair_color clothes_color head_dir guildID sex coords act lv)]],
		'0079' => ['actor_display', 'a4 v14 a4 x7 C1 a3 x2 v1',    [qw(ID walk_speed param1 param2 param3 type hair_style weapon lowhead shield tophead midhead hair_color clothes_color head_dir guildID sex coords lv)]],
		'007A' => ['changeToInGameState'],
		'007B' => ['actor_display', 'a4 v8 x4 v6 a4 x7 C1 a5 x3 v1',     [qw(ID walk_speed param1 param2 param3 type hair_style weapon lowhead shield tophead midhead hair_color clothes_color head_dir guildID sex coords lv)]],
		'007C' => ['actor_display', 'a4 v1 v1 v1 v1 x6 v1 C1 x12 C1 a3', [qw(ID walk_speed param1 param2 param3 type pet sex coords)]],
		'007F' => ['received_sync', 'V1', [qw(time)]],
	#.mod altsync {
		'014E' => ['received_sync', 'V1', [qw(time)]],
	#}
		'0080' => ['actor_died_or_disappeared', 'a4 C1', [qw(ID type)]],
		'0081' => ['errors', 'C1', [qw(type)]],
		'0086' => ['actor_display', 'a4 a5', [qw(ID coords)]],
		'0087' => ['character_moves', 'x4 a5 C1', [qw(coords unknown)]],
		'0088' => ['actor_movement_interrupted', 'a4 v1 v1', [qw(ID x y)]],
		'008A' => ['actor_action', 'a4 a4 a4 V2 v1 v1 C1 v1', [qw(sourceID targetID tick src_speed dst_speed damage param2 type param3)]],
		'008D' => ['public_chat', 'v1 a4 Z*', [qw(len ID message)]],
		'008E' => ['self_chat', 'x2 Z*', [qw(message)]],
		'0091' => ['map_change', 'Z16 v1 v1', [qw(map x y)]],
		'0092' => ['map_changed', 'Z16 x4 a4 v1', [qw(map IP port)]],
		'0095' => ['actor_info', 'a4 Z24', [qw(ID name)]],
		'0097' => ['private_message', 'v1 Z24 Z*', [qw(len privMsgUser privMsg)]],
		'0098' => ['private_message_sent', 'C1', [qw(type)]],
		'009A' => ['system_chat', 'x2 Z*', [qw(message)]], #maybe use a* instead and $message =~ /\000$//; if there are problems
		'009C' => ['actor_look_at', 'a4 C1 x1 C1', [qw(ID head body)]],
		'009D' => ['item_exists', 'a4 v1 x1 v3', [qw(ID type x y amount)]],
		'009E' => ['item_appeared', 'a4 v1 x1 v1 v1 x2 v1', [qw(ID type x y amount)]],
		'00A0' => ['inventory_item_added', 'v1 v1 v1 C1 C1 C1 a8 v1 C1 C1', [qw(index amount nameID identified broken upgrade cards type_equip type fail)]],
		'00A1' => ['item_disappeared', 'a4', [qw(ID)]],
		'00A3' => ['inventory_items_stackable'],
		'00A4' => ['inventory_items_nonstackable'],
		'00A5' => ['storage_items_stackable'],
		'00A6' => ['storage_items_nonstackable'],
		'00A8' => ['use_item', 'v1 x2 C1', [qw(index amount)]],
		'00AA' => ['equip_item', 'v1 v1 C1', [qw(index type success)]],
		'00AC' => ['unequip_item', 'v1 v1', [qw(index type)]],
		'00AF' => ['inventory_item_removed', 'v1 v1', [qw(index amount)]],
		'00B0' => ['stat_info', 'v1 V1', [qw(type val)]],
		'00B1' => ['exp_zeny_info', 'v1 V1', [qw(type val)]],
		'00B3' => ['switch_character'],
		'00B4' => ['npc_talk'],
		'00B5' => ['npc_talk_continue'],
		'00B6' => ['npc_talk_close', 'a4', [qw(ID)]],
		'00B7' => ['npc_talk_responses'],
		'00BC' => ['stats_added', 'v1 x1 C1', [qw(type val)]],
		'00BD' => ['stats_info', 'v1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 v1 v1 v1 v1 v1 v1 v1 v1 v1 v1 v1 v1', [qw(points_free str points_str agi points_agi vit points_vit int points_int dex points_dex luk points_luk attack attack_bonus attack_magic_min attack_magic_max def def_bonus def_magic def_magic_bonus hit flee flee_bonus critical)]],
		'00BE' => ['stats_points_needed', 'v1 C1', [qw(type val)]],
		'00C0' => ['emoticon', 'a4 C1', [qw(ID type)]],
		'00CA' => ['buy_result', 'C1', [qw(fail)]],
		'00C2' => ['users_online', 'V1', [qw(users)]],
		'00C3' => ['job_equipment_hair_change', 'a4 C1 C1', [qw(ID part number)]],
		'00C4' => ['npc_store_begin', 'a4', [qw(ID)]],
		'00C6' => ['npc_store_info'],
		'00C7' => ['npc_sell_list'],
		'00D1' => ['ignore_player_result', 'C1 C1', [qw(type error)]],
		'00D2' => ['ignore_all_result', 'C1 C1', [qw(type error)]],
		'00D6' => ['chat_created'],
		'00D7' => ['chat_info', 'x2 a4 a4 v1 v1 C1 a*', [qw(ownerID ID limit num_users public title)]],
		'00DA' => ['chat_join_result', 'C1', [qw(type)]],
		'00D8' => ['chat_removed', 'a4', [qw(ID)]],
		'00DB' => ['chat_users'],
		'00DC' => ['chat_user_join', 'v1 Z24', [qw(num_users user)]],
		'00DD' => ['chat_user_leave', 'v1 Z24', [qw(num_users user)]],
		'00DF' => ['chat_modified', 'x2 a4 a4 v1 v1 C1 a*', [qw(ownerID ID limit num_users public title)]],
		'00E1' => ['chat_newowner', 'C1 x3 Z24', [qw(type user)]],
		'00E5' => ['deal_request', 'Z24', [qw(user)]],
		'00E7' => ['deal_begin', 'C1', [qw(type)]],
		'00E9' => ['deal_add_other', 'V1 v1 C1 C1 C1 a8', [qw(amount nameID identified broken upgrade cards)]],
		'00EA' => ['deal_add_you', 'v1 C1', [qw(index fail)]],
		'00EC' => ['deal_finalize', 'C1', [qw(type)]],
		'00EE' => ['deal_cancelled'],
		'00F0' => ['deal_complete'],
		'00F2' => ['storage_opened', 'v1 v1', [qw(items items_max)]],
		'00F4' => ['storage_item_added', 'v1 V1 v1 C1 C1 C1 a8', [qw(index amount ID identified broken upgrade cards)]],
		'00F6' => ['storage_item_removed', 'v1 V1', [qw(index amount)]],
		'00F8' => ['storage_closed'],
		'00FA' => ['party_organize_result', 'C1', [qw(fail)]],
		'00FB' => ['party_users_info', 'x2 Z24', [qw(party_name)]],
		'00FD' => ['party_invite_result', 'Z24 C1', [qw(name type)]],
		'00FE' => ['party_invite', 'a4 Z24', [qw(ID name)]],
		'0101' => ['party_exp', 'C1', [qw(type)]],
		'0104' => ['party_join', 'a4 x4 v1 v1 C1 Z24 Z24 Z16', [qw(ID x y type name user map)]],
		'0105' => ['party_leave', 'a4 Z24', [qw(ID name)]],
		'0106' => ['party_hp_info', 'a4 v1 v1', [qw(ID hp hp_max)]],
		'0107' => ['party_location', 'a4 v1 v1', [qw(ID x y)]],
		'0108' => ['item_upgrade', 'v1 v1 v1', [qw(type index upgrade)]],
		'0109' => ['party_chat', 'x2 a4 Z*', [qw(ID message)]],
		'0110' => ['skill_use_failed', 'v1 v1 v1 C1 C1', [qw(skillID btype unknown fail type)]],
		'010A' => ['mvp_item', 'v1', [qw(itemID)]],
		'010B' => ['mvp_you', 'V1', [qw(expAmount)]],
		'010C' => ['mvp_other', 'a4', [qw(ID)]],
		'010E' => ['skill_update', 'v1 v1 v1 v1 C1', [qw(skillID lv sp range up)]], # range = skill range, up = this skill can be leveled up further
		'010F' => ['skills_list'],
		'0114' => ['skill_use', 'v1 a4 a4 V1 V1 V1 v1 v1 v1 C1', [qw(skillID sourceID targetID tick src_speed dst_speed damage level param3 type)]],
		'0117' => ['skill_use_location', 'v1 a4 v1 v1 v1', [qw(skillID sourceID lv x y)]],
		'0119' => ['character_status', 'a4 v3 x', [qw(ID param1 param2 param3)]],
		'011A' => ['skill_used_no_damage', 'v1 v1 a4 a4 C1', [qw(skillID amount targetID sourceID fail)]],
		'011C' => ['warp_portal_list', 'v1 Z16 Z16 Z16 Z16', [qw(type memo1 memo2 memo3 memo4)]],
		'011E' => ['memo_success', 'C1', [qw(fail)]],
		'011F' => ['area_spell', 'a4 a4 v2 C2', [qw(ID sourceID x y type fail)]],
		'0120' => ['area_spell_disappears', 'a4', [qw(ID)]],
		'0121' => ['cart_info', 'v1 v1 V1 V1', [qw(items items_max weight weight_max)]],
		'0122' => ['cart_equip_list'],
		'0123' => ['cart_items_list'],
		'0124' => ['cart_item_added', 'v1 V1 v1 x C1 C1 C1 a8', [qw(index amount ID identified broken upgrade cards)]],
		'0125' => ['cart_item_removed', 'v1 V1', [qw(index amount)]],
		'012C' => ['cart_add_failed', 'C1', [qw(fail)]],
		'012D' => ['shop_skill', 'v1', [qw(number)]],
		'0131' => ['vender_found', 'a4 A30', [qw(ID title)]],
		'0132' => ['vender_lost', 'a4', [qw(ID)]],
		'0133' => ['vender_items_list'],
		'0135' => ['vender_buy_fail', 'v1 v1 C1', [qw(index amount fail)]],
		'0136' => ['vending_start'],
		'0137' => ['shop_sold', 'v1 v1', [qw(number amount)]],
		'0139' => ['monster_ranged_attack', 'a4 v1 v1 v1 v1 C1', [qw(ID sourceX sourceY targetX targetY type)]],
		'013A' => ['attack_range', 'v1', [qw(type)]],
		'013B' => ['arrow_none', 'v1', [qw(type)]],
		'013D' => ['hp_sp_changed', 'v1 v1', [qw(type amount)]],
		'013E' => ['skill_cast', 'a4 a4 v1 v1 v1 v1 v1 V1', [qw(sourceID targetID x y skillID unknown type wait)]],		
		'013C' => ['arrow_equipped', 'v1', [qw(index)]],
		'0141' => ['stat_info2', 'v1 x2 v1 x2 v1', [qw(type val val2)]],
		'0142' => ['npc_talk_number', 'a4', [qw(ID)]],
		'0144' => ['minimap_indicator', 'V1 V1 V1 V1 v1 x3', [qw(ID clear x y color)]],
		'0147' => ['item_skill', 'v1 v1 v1 v1 v1 v1 A*', [qw(skillID targetType unknown skillLv sp unknown2 skillName)]],
		'0148' => ['resurrection', 'a4 v1', [qw(targetID type)]],
		'014C' => ['guild_allies_enemy_list'],
		'0154' => ['guild_members_list'],
		'015A' => ['guild_leave', 'Z24 Z40', [qw(name message)]],
		'015C' => ['guild_expulsion', 'Z24 Z40 Z24', [qw(name message unknown)]],
		'015E' => ['guild_broken', 'V1', [qw(flag)]], # clif_guild_broken
		'0160' => ['guild_member_setting_list'],
		'0162' => ['guild_skills_list'],
		'0163' => ['guild_expulsionlist'],
		'0166' => ['guild_members_title_list'],
		'0167' => ['guild_create_result', 'C1', [qw(type)]],
		'0169' => ['guild_invite_result', 'C1', [qw(type)]],
		'016A' => ['guild_request', 'a4 Z24', [qw(ID name)]],
		'016C' => ['guild_name', 'a4, V2 x5 Z24', [qw(guildID emblemID mode guildName)]],
		'016D' => ['guild_member_online_status', 'a4 a4 V1', [qw(ID charID online)]],
		'016F' => ['guild_notice'],
		'0171' => ['guild_ally_request', 'a4 Z24', [qw(ID name)]],
		#'0173' => ['guild_alliance', 'V1', [qw(flag)]],
		'0177' => ['identify_list'],
		'0179' => ['identify', 'v*', [qw(index)]],
		'017B' => ['card_merge_list'],
		'017D' => ['card_merge_status', 'v1 v1 C1', [qw(item_index card_index fail)]],
		'017F' => ['guild_chat', 'x2 Z*', [qw(message)]],
		#'0181' => ['guild_opposition_result', 'C1', [qw(flag)]], # clif_guild_oppositionack
		#'0184' => ['guild_unally', 'a4 V1', [qw(guildID flag)]], # clif_guild_delalliance
		'0187' => ['sync_request', 'a4', [qw(ID)]],
		'0188' => ['item_upgrade', 'v1 v1 v1', [qw(type index upgrade)]],
		'0189' => ['no_teleport', 'v1', [qw(fail)]],
		'018C' => ['sense_result', 'v1 v1 v1 V1 v1 v1 v1 v1 C1 C1 C1 C1 C1 C1 C1 C1 C1', [qw(nameID level size hp def race mdef element ice earth fire wind poison holy dark spirit undead)]],
		'018D' => ['forge_list'],
		'018F' => ['refine_result', 'v1 v1', [qw(fail nameID)]],
		#'0191' => ['talkie_box', 'a4 Z80', [qw(ID message)]], # talkie box message
		'0194' => ['character_name', 'a4 Z24', [qw(ID name)]],
		'0195' => ['actor_name_received', 'a4 Z24 Z24 Z24 Z24', [qw(ID name partyName guildName guildTitle)]],
		'0196' => ['actor_status_active', 'v1 a4 C1', [qw(type ID flag)]],
		'0199' => ['pvp_mode1', 'v1', [qw(type)]],
		'019A' => ['pvp_rank', 'x2 V1 V1 V1', [qw(ID rank num)]],
		'019B' => ['unit_levelup', 'a4 V1', [qw(ID type)]],
		'01A0' => ['pet_capture_result', 'C1', [qw(type)]],
		'01A2' => ['pet_info', 'Z24 C1 v4', [qw(name nameflag level hungry friendly accessory)]],
		'01A3' => ['pet_food', 'C1 v1', [qw(success foodID)]],
		'01A4' => ['pet_info2', 'C a4 V', [qw(type ID value)]],
		'01A6' => ['egg_list'],
		'01AA' => ['pet_emotion', 'a4 V1', [qw(ID type)]],
		'01AB' => ['actor_muted', 'x2 a4 x2 L1', [qw(ID duration)]],
		'01AC' => ['actor_trapped', 'a4', [qw(ID)]],
		'01AD' => ['arrowcraft_list'],
		'01B0' => ['monster_typechange', 'a4 a1 V1', [qw(ID unknown type)]],
		'01B3' => ['npc_image', 'Z63 C1', [qw(npc_image type)]],
		'01B5' => ['account_payment_info', 'V1 V1', [qw(D_minute H_minute)]],
		'01B6' => ['guild_info', 'a4 V1 V1 V1 V1 V1 V1 x12 V1 Z24 Z24', [qw(ID lvl conMember maxMember average exp next_exp members name master)]],
		'01B9' => ['cast_cancelled', 'a4', [qw(ID)]],
		'01C3' => ['local_broadcast', 'x2 a3 x9 Z*', [qw(color message)]],
		'01C4' => ['storage_item_added', 'v1 V1 v1 C1 C1 C1 C1 a8', [qw(index amount ID type identified broken upgrade cards)]],
		'01C5' => ['cart_item_added', 'v1 V1 v1 x C1 C1 C1 a8', [qw(index amount ID identified broken upgrade cards)]],
		'01C8' => ['item_used', 'v1 v1 a4 v1', [qw(index itemID ID remaining)]],
		'01C9' => ['area_spell', 'a4 a4 v2 C2 C Z80', [qw(ID sourceID x y type fail scribbleLen scribbleMsg)]],
		'01CD' => ['sage_autospell'],
		'01CF' => ['devotion', 'a4 a20', [qw(sourceID data)]],
		'01D0' => ['revolving_entity', 'a4 v', [qw(sourceID entity)]],
		'01D2' => ['combo_delay', 'a4 V1', [qw(ID delay)]],
		'01D4' => ['npc_talk_text', 'a4', [qw(ID)]],
		'01D7' => ['player_equipment', 'a4 C1 v2', [qw(sourceID type ID1 ID2)]],
		'01D8' => ['actor_display', 'a4 v14 a4 x4 v1 x1 C1 a3 x2 C1 v1', [qw(ID walk_speed param1 param2 param3 type hair_style weapon shield lowhead tophead midhead hair_color clothes_color head_dir guildID skillstatus sex coords act lv)]],
		'01D9' => ['actor_display', 'a4 v14 a4 x4 v1 x1 C1 a3 x2 v1',    [qw(ID walk_speed param1 param2 param3 type hair_style weapon shield lowhead tophead midhead hair_color clothes_color head_dir guildID skillstatus sex coords lv)]],
		'01DA' => ['actor_display', 'a4 v5 C1 x1 v3 x4 v5 a4 x4 v1 x1 C1 a5 x3 v1', [qw(ID walk_speed param1 param2 param3 type hair_style weapon shield lowhead tophead midhead hair_color clothes_color head_dir guildID skillstatus sex coords lv)]],
		'01DC' => ['secure_login_key', 'x2 a*', [qw(secure_key)]],
		'01D6' => ['pvp_mode2', 'v1', [qw(type)]],
		'01DE' => ['skill_use', 'v1 a4 a4 V1 V1 V1 V1 v1 v1 C1', [qw(skillID sourceID targetID tick src_speed dst_speed damage level param3 type)]],
		'01E1' => ['revolving_entity', 'a4 v1', [qw(sourceID entity)]],
		#'01E2' => ['marriage_unknown'], clif_parse_ReqMarriage
		#'01E4' => ['marriage_unknown'], clif_marriage_process
		##
		#01E6 26 Some Player Name.
		'01E9' => ['party_join', 'a4 x4 v1 v1 C1 Z24 Z24 Z16 v C2', [qw(ID x y type name user map lv item_pickup item_share)]],
		'01EB' => ['guild_location', 'a4 v1 v1', [qw(ID x y)]],
		'01EA' => ['married', 'a4', [qw(ID)]],
		'01EE' => ['inventory_items_stackable'],
		'01EF' => ['cart_items_list'],
		'01F2' => ['guild_member_online_status', 'a4 a4 V1 v3', [qw(ID charID online sex hair_style hair_color)]],
		'01F4' => ['deal_request', 'Z24 x4 v1', [qw(user level)]],
		'01F5' => ['deal_begin', 'C1 a4 v1', [qw(type targetID level)]],
		#'01F6' => ['adopt_unknown'], # clif_parse_ReqAdopt
		#'01F8' => ['adopt_unknown'], # clif_adopt_process
		'01F0' => ['storage_items_stackable'],
		'01FC' => ['repair_list'],
		'01FE' => ['repair_result', 'v1 C1', [qw(nameID flag)]],
		'0201' => ['friend_list'],
		#'0205' => ['divorce_unknown', 'Z24', [qw(name)]], # clif_divorced
		'0206' => ['friend_logon', 'a4 a4 C1', [qw(friendAccountID friendCharID isNotOnline)]],
		'0207' => ['friend_request', 'a4 a4 Z24', [qw(accountID charID name)]],
		'0209' => ['friend_response', 'C1 Z24', [qw(type name)]],
		'020A' => ['friend_removed', 'a4 a4', [qw(friendAccountID friendCharID)]],
		'020E' => ['taekwon_mission_receive', 'Z24 a4 c1', [qw(monName ID value)]],
		'0219' => ['top10_blacksmith_rank'],
		'021A' => ['top10_alchemist_rank'],
		'021B' => ['blacksmith_points', 'V1 V1', [qw(points total)]],
		'021C' => ['alchemist_point', 'V1 V1', [qw(points total)]],
		'0224' => ['taekwon_rank', 'c1 x3 c1', [qw(type rank)]],
		'0226' => ['top10_taekwon_rank'],
		'0227' => ['gameguard_request'],
		'0229' => ['character_status', 'a4 v1 v1 v1', [qw(ID param1 param2 param3)]],
		'022A' => ['actor_display', 'a4 v4 x2 v8 x2 v a4 a4 v x2 C2 a3 x2 C v', [qw(ID walk_speed param1 param2 param3 type hair_style weapon shield lowhead tophead midhead hair_color head_dir guildID guildEmblem visual_effects stance sex coords act lv)]],
		'022B' => ['actor_display', 'a4 v4 x2 v8 x2 v a4 a4 v x2 C2 a3 x2 v', [qw(ID walk_speed param1 param2 param3 type hair_style weapon shield lowhead tophead midhead hair_color head_dir guildID guildEmblem visual_effects stance sex coords lv)]],
		'022C' => ['actor_display', 'a4 v4 x2 v5 V1 v3 x4 a4 a4 v x2 C2 a5 x3 v', [qw(ID walk_speed param1 param2 param3 type hair_style weapon shield lowhead timestamp tophead midhead hair_color guildID guildEmblem visual_effects stance sex coords lv)]],
		'022E' => ['homunculus_stats', 'Z24 C v16 V2 v2', [qw(name state lvl hunger intimacy accessory atk matk hit critical def mdef flee aspd hp hp_max sp sp_max exp exp_max points_skill unknown)]],
		'022F' => ['homunculus_food', 'C1 v1', [qw(success foodID)]],
		'0230' => ['homunculus_info', 'x1 C1 a4 V1',[qw(type ID val)]],
		'0235' => ['homunculus_skills'],
		'0238' => ['top10_pk_rank'],
		# homunculus skill update
		'0239' => ['skill_update', 'v1 v1 v1 v1 C1', [qw(skillID lv sp range up)]], # range = skill range, up = this skill can be leveled up further
		'023A' => ['storage_password_request', 'v1', [qw(flag)]],
		'023C' => ['storage_password_result', 'v1 v1', [qw(type val)]],
		'023E' => ['storage_password_request', 'v1', [qw(flag)]],
		'0259' => ['gameguard_grant', 'C1', [qw(server)]],
		'0274' => ['account_server_info', 'x2 a4 a4 a4 x30 C1 x4 a*', [qw(sessionID accountID sessionID2 accountSex serverInfo)]],
		# tRO new packets, need some work on them
		'0295' => ['inventory_items_equiped'],
		'029A' => ['inventory_item_added', 'v1 v1 v1 C1 C1 C1 a10 v1 v1 v1', [qw(index amount nameID identified broken upgrade cards type_equip type fail)]],
	};

	return bless \%self, $class;
}

##
# boolean $packetParser->willMangle(Bytes messageID)
#
# Check whether the message with the specified message ID will be mangled.
# If the bot is running in X-Kore mode, then messages that will be mangled will not
# be sent to the RO client.
sub willMangle {
	my ($self, $messageID) = @_;

	my $packet = $self->{packet_list}{$messageID};
	my $name;
	$name = $packet->[0] if ($packet);

	my %args = (
		messageID => $messageID,
		name => $name
	);
	Plugins::callHook("Network::Receive/willMangle", \%args);
	return $args{willMangle};
}

# $NetworkReceive->mangle($args)
#
# Calls the appropriate plugin function to mangle the packet, which
# destructively modifies $args.
# Returns false if the packet should be suppressed.
sub mangle {
	my ($self, $args) = @_;

	my %hook_args = (message => $args);
	my $entry = $self->{packet_list}{$args->{switch}};
	if ($entry) {
		$hook_args{messageName} = $entry->[0];
	}

	Plugins::callHook("Network::Receive/mangle", \%hook_args);
	if (exists $hook_args{ret}) {
		return $hook_args{ret};
	} else {
		return 0;
	}
}

# $NetworkReceive->reconstruct($args)
#
# Reconstructs a raw packet from $args using $self->{packet_list}.
sub reconstruct {
	my ($self, $args) = @_;

	my $switch = $args->{switch};
	my $packet = $self->{packet_list}{$switch};
	my ($name, $packString, $varNames) = @{$packet};

	my @vars = ();
	for my $varName (@{$varNames}) {
		push(@vars, $args->{$varName});
	}
	my $packet = pack("H2 H2 $packString", substr($switch, 2, 2), substr($switch, 0, 2), @vars);
	return $packet;
}

##
# Network::Receive->create(serverType)
sub create {
	my ($self, $type) = @_;
	($type) = $type =~ /([0-9_]+)/;
	$type = 0 if $type eq '';
	my $class = "Network::Receive::ServerType" . $type;

	undef $@;
	eval "use $class;";
	if ($@) {
		error TF("Cannot load packet parser for ServerType '%s'.\n", $type);
		return;
	}

	return eval "new $class;";
}

sub parse {
	my ($self, $msg) = @_;

	$bytesReceived += length($msg);
	my $switch = uc(unpack("H2", substr($msg, 1, 1))) . uc(unpack("H2", substr($msg, 0, 1)));
	my $handler = $self->{packet_list}{$switch};
	return 0 unless $handler;

	debug "Received packet: $switch Handler: $handler->[0]\n", "packetParser", 2;

	# RAW_MSG is the entire message, including packet switch
	my %args;
	$args{switch} = $switch;
	$args{RAW_MSG} = $msg;
	$args{RAW_MSG_SIZE} = length($msg);
	if ($handler->[1]) {
		my @unpacked_data = unpack("x2 $handler->[1]", $msg);
		my $keys = $handler->[2];
		foreach my $key (@{$keys}) {
			$args{$key} = shift @unpacked_data;
		}
	}

	my $callback = $self->can($handler->[0]);
	if ($callback) {
		Plugins::callHook("packet_pre/$handler->[0]", \%args);
		Misc::checkValidity("Packet: " . $handler->[0] . " (pre)");
		$self->$callback(\%args);
		Misc::checkValidity("Packet: " . $handler->[0]);
	} else {
		debug "Packet Parser: Unhandled Packet: $switch Handler: $handler->[0]\n", "packetParser", 2;
	}

	Plugins::callHook("packet/$handler->[0]", \%args);
	return \%args;
}

##
# Network::Receive->decrypt(r_msg, themsg)
# r_msg: a reference to a scalar.
# themsg: the message to decrypt.
#
# Decrypts the packets in $themsg and put the result in the scalar
# referenced by $r_msg.
#
# This is an old method used back in the iRO beta 2 days when iRO had encrypted packets.
# At the moment (December 20 2006) there are no servers that still use encrypted packets.
#
# Example:
# } elsif ($switch eq "ABCD") {
# 	my $level;
# 	Network::Receive->decrypt(\$level, substr($msg, 0, 2));
sub decrypt {
	use bytes;
	my ($self, $r_msg, $themsg) = @_;
	my @mask;
	my $i;
	my ($temp, $msg_temp, $len_add, $len_total, $loopin, $len, $val);
	if ($config{'encrypt'} == 1) {
		undef $$r_msg;
		undef $len_add;
		undef $msg_temp;
		for ($i = 0; $i < 13;$i++) {
			$mask[$i] = 0;
		}
		$len = unpack("v1",substr($themsg,0,2));
		$val = unpack("v1",substr($themsg,2,2));
		{
			use integer;
			$temp = ($val * $val * 1391);
		}
		$temp = ~(~($temp));
		$temp = $temp % 13;
		$mask[$temp] = 1;
		{
			use integer;
			$temp = $val * 1397;
		}
		$temp = ~(~($temp));
		$temp = $temp % 13;
		$mask[$temp] = 1;
		for($loopin = 0; ($loopin + 4) < $len; $loopin++) {
 			if (!($mask[$loopin % 13])) {
  				$msg_temp .= substr($themsg,$loopin + 4,1);
			}
		}
		if (($len - 4) % 8 != 0) {
			$len_add = 8 - (($len - 4) % 8);
		}
		$len_total = $len + $len_add;
		$$r_msg = $msg_temp.substr($themsg, $len_total, length($themsg) - $len_total);
	} elsif ($config{'encrypt'} >= 2) {
		undef $$r_msg;
		undef $len_add;
		undef $msg_temp;
		for ($i = 0; $i < 17;$i++) {
			$mask[$i] = 0;
		}
		$len = unpack("v1",substr($themsg,0,2));
		$val = unpack("v1",substr($themsg,2,2));
		{
			use integer;
			$temp = ($val * $val * 34953);
		}
		$temp = ~(~($temp));
		$temp = $temp % 17;
		$mask[$temp] = 1;
		{
			use integer;
			$temp = $val * 2341;
		}
		$temp = ~(~($temp));
		$temp = $temp % 17;
		$mask[$temp] = 1;
		for($loopin = 0; ($loopin + 4) < $len; $loopin++) {
 			if (!($mask[$loopin % 17])) {
  				$msg_temp .= substr($themsg,$loopin + 4,1);
			}
		}
		if (($len - 4) % 8 != 0) {
			$len_add = 8 - (($len - 4) % 8);
		}
		$len_total = $len + $len_add;
		$$r_msg = $msg_temp.substr($themsg, $len_total, length($themsg) - $len_total);
	} else {
		$$r_msg = $themsg;
	}
}


#######################################
###### Packet handling callbacks ######
#######################################


sub account_payment_info {
	my ($self, $args) = @_;
my $D_minute = $args->{D_minute};
	my $H_minute = $args->{H_minute};

	my $D_d = int($D_minute / 1440);
	my $D_h = int(($D_minute % 1440) / 60);
	my $D_m = int(($D_minute % 1440) % 60);

	my $H_d = int($H_minute / 1440);
	my $H_h = int(($H_minute % 1440) / 60);
	my $H_m = int(($H_minute % 1440) % 60);

	message  T("============= Account payment information =============\n"), "info";
	message TF("Pay per day  : %s day(s) %s hour(s) and %s minute(s)\n", $D_d, $D_h, $D_m), "info";
	message TF("Pay per hour : %s day(s) %s hour(s) and %s minute(s)\n", $H_d, $H_h, $H_m), "info";
	message  T("-------------------------------------------------------\n"), "info";
}

sub account_server_info {
	my ($self, $args) = @_;
	my $msg = $args->{serverInfo};
	my $msg_size = length($msg);

	$net->setState(2);
	undef $conState_tries;
	$sessionID = $args->{sessionID};
	$accountID = $args->{accountID};
	$sessionID2 = $args->{sessionID2};
	# Account sex should only be 0 (female) or 1 (male)
	# inRO gives female as 2 but expects 0 back
	# do modulus of 2 here to fix?
	# FIXME: we should check exactly what operation the client does to the number given
	$accountSex = $args->{accountSex} % 2;
	$accountSex2 = ($config{'sex'} ne "") ? $config{'sex'} : $accountSex;

	message swrite(
		T("-----------Account Info------------\n" . 
		"Account ID: \@<<<<<<<<< \@<<<<<<<<<<\n" .
		"Sex:        \@<<<<<<<<<<<<<<<<<<<<<\n" .
		"Session ID: \@<<<<<<<<< \@<<<<<<<<<<\n" .
		"            \@<<<<<<<<< \@<<<<<<<<<<\n" .
		"-----------------------------------"), 
		[unpack("V1",$accountID), getHex($accountID), $sex_lut{$accountSex}, unpack("V1",$sessionID), getHex($sessionID),
		unpack("V1",$sessionID2), getHex($sessionID2)]), 'connection';

	my $num = 0;
	undef @servers;
	for (my $i = 0; $i < $msg_size; $i+=32) {
		$servers[$num]{ip} = makeIP(substr($msg, $i, 4));
		$servers[$num]{ip} = $masterServer->{ip} if ($masterServer && $masterServer->{private});
		$servers[$num]{port} = unpack("v1", substr($msg, $i+4, 2));
		($servers[$num]{name}) = bytesToString(unpack("Z*", substr($msg, $i + 6, 20)));
		$servers[$num]{users} = unpack("V",substr($msg, $i + 26, 4));
		$num++;
	}

	message T("--------- Servers ----------\n" .
			"#   Name                  Users  IP              Port\n"), 'connection';
	for (my $num = 0; $num < @servers; $num++) {
		message(swrite(
			"@<< @<<<<<<<<<<<<<<<<<<<< @<<<<< @<<<<<<<<<<<<<< @<<<<<",
			[$num, $servers[$num]{name}, $servers[$num]{users}, $servers[$num]{ip}, $servers[$num]{port}]
		), 'connection');
	}
	message("-------------------------------\n", 'connection');

	if ($net->version != 1) {
		message T("Closing connection to Account Server\n"), 'connection';
		$net->serverDisconnect();
		if (!$masterServer->{charServer_ip} && $config{server} eq "") {
			my @serverList;
			foreach my $server (@servers) {
				push @serverList, $server->{name};
			}
			my $ret = $interface->showMenu(
					T("Please select your login server."),
					\@serverList,
					title => T("Select Login Server"));
			if ($ret == -1) {
				quit();
			} else {
				main::configModify('server', $ret, 1);
			}

		} elsif ($masterServer->{charServer_ip}) {
			message TF("Forcing connect to char server %s: %s\n", $masterServer->{charServer_ip}, $masterServer->{charServer_port}), 'connection';	
			
		} else {
			message TF("Server %s selected\n",$config{server}), 'connection';
		}
	}
}

sub actor_action {
	my ($self,$args) = @_;
	changeToInGameState();

	if ($args->{type} == 1) {
		# Take item
		my $source = Actor::get($args->{sourceID});
		my $verb = $source->verb('pick up', 'picks up');
		my $target = getActorName($args->{targetID});
		debug "$source $verb $target\n", 'parseMsg_presence';

		my $item = $itemsList->getByID($args->{targetID});
		$item->{takenBy} = $args->{sourceID} if ($item);

	} elsif ($args->{type} == 2) {
		# Sit
		my ($source, $verb) = getActorNames($args->{sourceID}, 0, 'are', 'is');
		if ($args->{sourceID} eq $accountID) {
			message T("You are sitting.\n");
			$char->{sitting} = 1;
			AI::queue("sitAuto") unless (AI::inQueue("sitAuto")) || $ai_v{sitAuto_forcedBySitCommand};
		} else {
			message TF("%s is sitting.\n", getActorName($args->{sourceID})), 'parseMsg_statuslook', 2;
			my $player = $playersList->getByID($args->{sourceID});
			$player->{sitting} = 1 if ($player);
		}
		Misc::checkValidity("actor_action (take item)");

	} elsif ($args->{type} == 3) {
		# Stand
		my ($source, $verb) = getActorNames($args->{sourceID}, 0, 'are', 'is');
		if ($args->{sourceID} eq $accountID) {
			message T("You are standing.\n");
			if ($config{sitAuto_idle}) {
				$timeout{ai_sit_idle}{time} = time;
			}
			$char->{sitting} = 0;
		} else {
			message TF("%s is standing.\n", getActorName($args->{sourceID})), 'parseMsg_statuslook', 2;
			my $player = $playersList->getByID($args->{sourceID});
			$player->{sitting} = 0 if ($player);
		}
		Misc::checkValidity("actor_action (stand)");

	} else {
		# Attack
		my $dmgdisplay;
		my $totalDamage = $args->{damage} + $args->{param3};
		if ($totalDamage == 0) {
			$dmgdisplay = "Miss!";
			$dmgdisplay .= "!" if ($args->{type} == 11);
		} else {
			$dmgdisplay = $args->{damage};
			$dmgdisplay .= "!" if ($args->{type} == 10);
			$dmgdisplay .= " + $args->{param3}" if $args->{param3};
		}

		Misc::checkValidity("actor_action (attack 1)");

		updateDamageTables($args->{sourceID}, $args->{targetID}, $totalDamage);

		Misc::checkValidity("actor_action (attack 2)");

		my $source = Actor::get($args->{sourceID});
		my $target = Actor::get($args->{targetID});
		my $verb = $source->verb('attack', 'attacks');

		$target->{sitting} = 0 unless $args->{type} == 4 || $args->{type} == 9 || $totalDamage == 0;

		my $msg = attack_string($source, $target, $dmgdisplay, ($args->{src_speed}/10));
		Plugins::callHook('packet_attack', {sourceID => $args->{sourceID}, targetID => $args->{targetID}, msg => \$msg, dmg => $totalDamage, type => $args->{type}});

		my $status = sprintf("[%3d/%3d]", percent_hp($char), percent_sp($char));

		Misc::checkValidity("actor_action (attack 3)");

		if ($args->{sourceID} eq $accountID) {
			message("$status $msg", $totalDamage > 0 ? "attackMon" : "attackMonMiss");
			if ($startedattack) {
				$monstarttime = time();
				$monkilltime = time();
				$startedattack = 0;
			}
			Misc::checkValidity("actor_action (attack 4)");
			calcStat($args->{damage});
			Misc::checkValidity("actor_action (attack 5)");

		} elsif ($args->{targetID} eq $accountID) {
			message("$status $msg", $args->{damage} > 0 ? "attacked" : "attackedMiss");
			if ($args->{damage} > 0) {
				$damageTaken{$source->{name}}{attack} += $args->{damage};
			}

		} elsif ($char->{homunculus} && $args->{sourceID} eq $char->{homunculus}{ID}) {
			message(sprintf("[%3d/%3d]", $char->{homunculus}{hpPercent}, $char->{homunculus}{spPercent}) . " $msg", $totalDamage > 0 ? "attackMon" : "attackMonMiss");

		} elsif ($char->{homunculus} && $args->{targetID} eq $char->{homunculus}{ID}) {
			message(sprintf("[%3d/%3d]", $char->{homunculus}{hpPercent}, $char->{homunculus}{spPercent}) . " $msg", $args->{damage} > 0 ? "attacked" : "attackedMiss");

		} else {
			debug("$msg", 'parseMsg_damage');
		}

		Misc::checkValidity("actor_action (attack 6)");
	}
}

sub actor_died_or_disappeared {
	my ($self,$args) = @_;
	changeToInGameState();
	my $ID = $args->{ID};
	avoidList_ID($ID);
	
	if ($ID eq $accountID) {
		message T("You have died\n");
		closeShop() unless !$shopstarted || $config{'dcOnDeath'} == -1 || !$AI;
		$char->{deathCount}++;
		$char->{dead} = 1;
		$char->{dead_time} = time;

	} elsif (defined $monstersList->getByID($ID)) {
		my $monster = $monstersList->getByID($ID);
		if ($args->{type} == 0) {
			debug "Monster Disappeared: " . $monster->name . " ($monster->{binID})\n", "parseMsg_presence";
			$monster->{disappeared} = 1;

		} elsif ($args->{type} == 1) {
			debug "Monster Died: " . $monster->name . " ($monster->{binID})\n", "parseMsg_damage";
			$monster->{dead} = 1;

			if ($config{itemsTakeAuto_party} &&
			    ($monster->{dmgFromParty} > 0 ||
			     $monster->{dmgFromYou} > 0)) {
				AI::clear("items_take");
				ai_items_take($monster->{pos}{x}, $monster->{pos}{y},
					$monster->{pos_to}{x}, $monster->{pos_to}{y});
			}

		} elsif ($args->{type} == 2) { # What's this?
			debug "Monster Disappeared: " . $monster->name . " ($monster->{binID})\n", "parseMsg_presence";
			$monster->{disappeared} = 1;

		} elsif ($args->{type} == 3) {
			debug "Monster Teleported: " . $monster->name . " ($monster->{binID})\n", "parseMsg_presence";
			$monster->{teleported} = 1;
		}

		$monster->{gone_time} = time;
		$monsters_old{$ID} = $monster->deepCopy();
		$monstersList->remove($monster);

	} elsif (defined $playersList->getByID($ID)) {
		my $player = $playersList->getByID($ID);
		if ($args->{type} == 1) {
			message TF("Player Died: %s (%d) %s %s\n", $player->name, $player->{binID}, $sex_lut{$player->{sex}}, $jobs_lut{$player->{jobID}});
			if ($char->{homunculus} && $char->{homunculus}{ID} eq $player->{ID}) {
				$playersList->remove($player);
			} else {
				$player->{dead} = 1;
				$player->{dead_time} = time;
			}
		} else {
			if ($args->{type} == 0) {
				debug "Player Disappeared: " . $player->name . " ($player->{binID}) $sex_lut{$player->{sex}} $jobs_lut{$player->{jobID}} ($player->{pos_to}{x}, $player->{pos_to}{y})\n", "parseMsg_presence";
				$player->{disappeared} = 1;
			} elsif ($args->{type} == 2) {
				debug "Player Disconnected: ".$player->name." ($player->{binID}) $sex_lut{$player->{sex}} $jobs_lut{$player->{jobID}} ($player->{pos_to}{x}, $player->{pos_to}{y})\n", "parseMsg_presence";
				$player->{disconnected} = 1;
			} elsif ($args->{type} == 3) {
				debug "Player Teleported: ".$player->name." ($player->{binID}) $sex_lut{$player->{sex}} $jobs_lut{$player->{jobID}} ($player->{pos_to}{x}, $player->{pos_to}{y})\n", "parseMsg_presence";
				$player->{teleported} = 1;
			} else {
				debug "Player Disappeared in an unknown way: ".$player->name." ($player->{binID}) $sex_lut{$player->{sex}} $jobs_lut{$player->{jobID}}\n", "parseMsg_presence";
				$player->{disappeared} = 1;
			}

			$player->{gone_time} = time;
			$players_old{$ID} = $player->deepCopy();
			$playersList->remove($player);
		}

	} elsif ($players_old{$ID}) {
		if ($args->{type} == 2) {
			debug "Player Disconnected: " . $players_old{$ID}->name . "\n", "parseMsg_presence";
			$players_old{$ID}{disconnected} = 1;
		} elsif ($args->{type} == 3) {
			debug "Player Teleported: " . $players_old{$ID}->name . "\n", "parseMsg_presence";
			$players_old{$ID}{teleported} = 1;
		}

	} elsif (defined $portalsList->getByID($ID)) {
		my $portal = $portalsList->getByID($ID);
		debug "Portal Disappeared: " . $portal->name . " ($portal->{binID})\n", "parseMsg";
		$portal->{disappeared} = 1;
		$portal->{gone_time} = time;
		$portals_old{$ID} = $portal->deepCopy();
		$portalsList->remove($portal);

	} elsif (defined $npcsList->getByID($ID)) {
		my $npc = $npcsList->getByID($ID);
		debug "NPC Disappeared: " . $npc->name . " ($npc->{nameID})\n", "parseMsg";
		$npc->{disappeared} = 1;
		$npc->{gone_time} = time;
		$npcs_old{$ID} = $npc->deepCopy();
		$npcsList->remove($npc);

	} elsif (defined $petsList->getByID($ID)) {
		my $pet = $petsList->getByID($ID);
		debug "Pet Disappeared: " . $pet->name . " ($pet->{binID})\n", "parseMsg";
		$pet->{disappeared} = 1;
		$pet->{gone_time} = time;
		$petsList->remove($pet);

	} else {
		debug "Unknown Disappeared: ".getHex($ID)."\n", "parseMsg";
	}
}

# This function is a merge of actor_exists, actor_connected, actor_moved, etc...
sub actor_display {
	my ($self, $args) = @_;
	changeToInGameState();
	my ($actor, $mustAdd);


	#### Initialize ####

	my $nameID = unpack("V1", $args->{ID});

	my (%coordsFrom, %coordsTo);
	if ($args->{switch} eq "007C") {
		makeCoords(\%coordsTo, $args->{coords});
		%coordsFrom = %coordsTo;
	} elsif ($args->{switch} eq "01DA") {
		makeCoords(\%coordsFrom, substr($args->{RAW_MSG}, 50, 3));
		makeCoords2(\%coordsTo, substr($args->{RAW_MSG}, 52, 3));
	} elsif (length($args->{coords}) >= 5) {
		my $coordsArg = $args->{coords};
		unShiftPack(\$coordsArg, \$coordsTo{y}, 10);
		unShiftPack(\$coordsArg, \$coordsTo{x}, 10);
		unShiftPack(\$coordsArg, \$coordsFrom{y}, 10);
		unShiftPack(\$coordsArg, \$coordsFrom{x}, 10);
	} else {
		my $coordsArg = $args->{coords};
		unShiftPack(\$coordsArg, \$args->{body_dir}, 4);
		unShiftPack(\$coordsArg, \$coordsTo{y}, 10);
		unShiftPack(\$coordsArg, \$coordsTo{x}, 10);
		%coordsFrom = %coordsTo;
	}
	
	if ($args->{switch} eq "0086") {
		# Message 0086 contains less information about the actor than other similar
		# messages. So we use the existing actor information.
		$args = Actor::get($args->{ID})->deepCopy();
		$args->{switch} = "0086";
	}

	# Remove actors with a distance greater than removeActorWithDistance. Useful for vending (so you don't spam
	# too many packets in prontera and cause server lag). As a side effect, you won't be able to "see" actors
	# beyond removeActorWithDistance.
	if ($config{removeActorWithDistance}) {
		if ((my $block_dist = blockDistance($char->{pos_to}, \%coordsTo)) > ($config{removeActorWithDistance})) {
			my $nameIdTmp = unpack("V1", $args->{ID});
			debug "Removed out of sight actor $nameIdTmp at ($coordsTo{x}, $coordsTo{y}) (distance: $block_dist)\n";
			return;
		}
	}


	#### Step 1: create/get the correct actor object ####

	if ($jobs_lut{$args->{type}}) {
		# Actor is a player (homunculus are considered players for now)
		$actor = $playersList->getByID($args->{ID});
		if (!defined $actor) {
			$actor = ($char->{homunculus} && $args->{ID} eq $char->{homunculus}{ID}) ? $char->{homunculus} : new Actor::Player($args->{type});
			$actor->{appear_time} = time;
			$mustAdd = 1;
		}
		$actor->{nameID} = $nameID;

	} elsif ($args->{type} == 45) {
		# Actor is a portal
		$actor = $portalsList->getByID($args->{ID});
		if (!defined $actor) {
			$actor = new Actor::Portal();
			$actor->{appear_time} = time;
			my $exists = portalExists($field{name}, \%coordsTo);
			$actor->{source}{map} = $field{name};
			if ($exists ne "") {
				$actor->setName("$portals_lut{$exists}{source}{map} -> " . getPortalDestName($exists));
			}
			$mustAdd = 1;

			# Strangely enough, portals (like all other actors) have names, too.
			# We _could_ send a "actor_info_request" packet to find the names of each portal,
			# however I see no gain from this. (And it might even provide another way of private
			# servers to auto-ban bots.)
		}
		$actor->{nameID} = $nameID;

	#} elsif ($args->{type} >= 1000 || ($args->{type} >= 6000 && $pvp == 0)) {
	} elsif ($args->{type} >= 1000) {
		# Actor might be a monster
		if ($args->{hair_style} == 0x64) {
			# Actor is a pet

			$actor = $petsList->getByID($args->{ID});
			if (!defined $actor) {
				$actor = new Actor::Pet();
				$actor->{appear_time} = time;
				if ($monsters_lut{$args->{type}}) {
					$actor->setName($monsters_lut{$args->{type}});
				}
				$actor->{name_given} = "Unknown";
				$mustAdd = 1;

				# Previously identified monsters could suddenly be identified as pets.
				if ($monstersList->getByID($args->{ID})) {
					$monstersList->removeByID($args->{ID});
				}
			}

		} else {
			# Actor really is a monster
			$actor = $monstersList->getByID($args->{ID});
			if (!defined $actor) {
				$actor = new Actor::Monster();
				$actor->{appear_time} = time;
				if ($monsters_lut{$args->{type}}) {
					$actor->setName($monsters_lut{$args->{type}});
				}
				$actor->{name_given} = "Unknown";
				$actor->{binType} = $args->{type};
				$mustAdd = 1;
			}
		}

		# Why do monsters and pets use nameID as type?
		$actor->{nameID} = $args->{type};

	} else {	# ($args->{type} < 1000 && $args->{type} != 45 && !$jobs_lut{$args->{type}})
		# Actor is an NPC
		$actor = $npcsList->getByID($args->{ID});
		if (!defined $actor) {
			$actor = new Actor::NPC();
			$actor->{appear_time} = time;
			$mustAdd = 1;
		}
		$actor->{nameID} = $nameID;
	}


	#### Step 2: update actor information ####

	$actor->{ID} = $args->{ID};
	$actor->{jobID} = $args->{type};
	$actor->{type} = $args->{type};
	$actor->{lv} = $args->{lv};
	$actor->{pos} = {%coordsFrom};
	$actor->{pos_to} = {%coordsTo};
	$actor->{walk_speed} = $args->{walk_speed} / 1000 if (exists $args->{walk_speed});
	$actor->{time_move} = time;
	$actor->{time_move_calc} = distance(\%coordsFrom, \%coordsTo) * $actor->{walk_speed};

	if (UNIVERSAL::isa($actor, "Actor::Player")) {
		# None of this stuff should matter if the actor isn't a player...

		# Interesting note about guildEmblem. If it is 0 (or none), the Ragnarok
		# client will display "Send (Player) a guild invitation" (assuming one has
		# invitation priveledges), regardless of whether or not guildID is set.
		# I bet that this is yet another brilliant "feature" by GRAVITY's good programmers.
		$actor->{guildEmblem} = $args->{guildEmblem} if (exists $args->{guildEmblem});
		$actor->{guildID} = $args->{guildID} if (exists $args->{guildID});

		if (exists $args->{lowhead}) {
			$actor->{headgear}{low} = $args->{lowhead};
			$actor->{headgear}{mid} = $args->{midhead};
			$actor->{headgear}{top} = $args->{tophead};
			$actor->{weapon} = $args->{weapon};
			$actor->{shield} = $args->{shield};
		}

		$actor->{sex} = $args->{sex};

		if ($args->{act} == 1) {
			$actor->{dead} = 1;
		} elsif ($args->{act} == 2) {
			$actor->{sitting} = 1;
		}

		# Monsters don't have hair colors or heads to look around...
		$actor->{hair_color} = $args->{hair_color} if (exists $args->{hair_color});
	}

	# But hair_style is used for pets, and their bodies can look different ways...
	$actor->{hair_style} = $args->{hair_style} if (exists $args->{hair_style});
	$actor->{look}{body} = $args->{body_dir} if (exists $args->{body_dir});
	$actor->{look}{head} = $args->{head_dir} if (exists $args->{head_dir});

	# When stance is non-zero, character is bobbing as if they had just got hit,
	# but the cursor also turns to a sword when they are mouse-overed.
	$actor->{stance} = $args->{stance} if (exists $args->{stance});

	# Visual effects are a set of flags
	$actor->{visual_effects} = $args->{visual_effects} if (exists $args->{visual_effects});

	# Known visual effects:
	# 0x0001 = Yellow tint (eg, a quicken skill)
	# 0x0002 = Red tint (eg, power-thrust)
	# 0x0004 = Gray tint (eg, energy coat)
	# 0x0008 = Slow lightning (eg, mental strength)
	# 0x0010 = Fast lightning (eg, MVP fury)
	# 0x0020 = Black non-moving statue (eg, stone curse)
	# 0x0040 = Translucent weapon
	# 0x0080 = Translucent red sprite (eg, marionette control?)
	# 0x0100 = Spaztastic weapon image (eg, mystical amplification)
	# 0x0200 = Gigantic glowy sphere-thing
	# 0x0400 = Translucent pink sprite (eg, marionette control?)
	# 0x0800 = Glowy sprite outline (eg, assumptio)
	# 0x1000 = Bright red sprite, slowly moving red lightning (eg, MVP fury?)
	# 0x2000 = Vortex-type effect

	# Note that these are flags, and you can mix and match them
	# Example: 0x000C (0x0008 & 0x0004) = gray tint with slow lightning

	# Save these parameters ...
	$actor->{param1} = $args->{param1};
	$actor->{param2} = $args->{param2};
	$actor->{param3} = $args->{param3};

	# And use them to set status flags.
	if (setStatus($actor, $args->{param1}, $args->{param2}, $args->{param3})) {
		$mustAdd = 0;
	}


	#### Step 3: Add actor to actor list ####

	if ($mustAdd) {
		if (UNIVERSAL::isa($actor, "Actor::Player")) {
			$playersList->add($actor);

		} elsif (UNIVERSAL::isa($actor, "Actor::Monster")) {
			$monstersList->add($actor);

		} elsif (UNIVERSAL::isa($actor, "Actor::Pet")) {
			$petsList->add($actor);

		} elsif (UNIVERSAL::isa($actor, "Actor::Portal")) {
			$portalsList->add($actor);

		} elsif (UNIVERSAL::isa($actor, "Actor::NPC")) {
			my $ID = $args->{ID};
			my $location = "$field{name} $actor->{pos}{x} $actor->{pos}{y}";
			if ($npcs_lut{$location}) {
				$actor->setName($npcs_lut{$location});
			}
			$npcsList->add($actor);
		}
	}


	#### Packet specific ####
	if ($args->{switch} eq "0078" ||
		$args->{switch} eq "01D8" ||
		$args->{switch} eq "022A") {
		# Actor Exists

		if ($actor->isa('Actor::Player')) {
			my $domain = existsInList($config{friendlyAID}, unpack("V1", $actor->{ID})) ? 'parseMsg_presence' : 'parseMsg_presence/player';
			debug "Player Exists: " . $actor->name . " ($actor->{binID}) Level $actor->{lv} $sex_lut{$actor->{sex}} $jobs_lut{$actor->{jobID}} ($coordsFrom{x}, $coordsFrom{y})\n", $domain;

			# Shouldn't this have a more specific hook name?
			Plugins::callHook('player', {player => $actor});

		} elsif ($actor->isa('Actor::NPC')) {
			message TF("NPC Exists: %s (%d, %d) (ID %d) - (%d)\n", $actor->name, $actor->{pos_to}{x}, $actor->{pos_to}{y}, $actor->{nameID}, $actor->{binID}), "parseMsg_presence", 1;

		} elsif ($actor->isa('Actor::Portal')) {
			message TF("Portal Exists: %s (%s, %s) - (%s)\n", $actor->name, $actor->{pos_to}{x}, $actor->{pos_to}{y}, $actor->{binID}), "portals", 1;

		} elsif ($actor->isa('Actor::Monster')) {
			debug sprintf("Monster Exists: %s (%d)\n", $actor->name, $actor->{binID}), "parseMsg_presence", 1;

		} elsif ($actor->isa('Actor::Pet')) {
			debug sprintf("Pet Exists: %s (%d)\n", $actor->name, $actor->{binID}), "parseMsg_presence", 1;

		} else {
			debug sprintf("Unknown Actor Exists: %s (%d)\n", $actor->name, $actor->{binID}), "parseMsg_presence", 1;
		}

	} elsif ($args->{switch} eq "0079" ||
		$args->{switch} eq "01DB" ||
		$args->{switch} eq "022B" ||
		$args->{switch} eq "01D9") {
		# Actor Connected

		if ($actor->isa('Actor::Player')) {
			my $domain = existsInList($config{friendlyAID}, unpack("V1", $args->{ID})) ? 'parseMsg_presence' : 'parseMsg_presence/player';
			debug "Player Connected: ".$actor->name." ($actor->{binID}) Level $args->{lv} $sex_lut{$actor->{sex}} $jobs_lut{$actor->{jobID}} ($coordsTo{x}, $coordsTo{y})\n", $domain;

			# Again, this hook name isn't very specific.
			Plugins::callHook('player', {player => $actor});
		} else {
			debug "Unknown Connected: $args->{type} - ", "parseMsg";
		}

	} elsif ($args->{switch} eq "007B" ||
		$args->{switch} eq "01DA" ||
		$args->{switch} eq "022C" ||
		$args->{switch} eq "0086") {
		# Actor Moved

		# Correct the direction in which they're looking
		my %vec;
		getVector(\%vec, \%coordsTo, \%coordsFrom);
		my $direction = int sprintf("%.0f", (360 - vectorToDegree(\%vec)) / 45);

		$actor->{look}{body} = $direction;
		$actor->{look}{head} = 0;

		if ($actor->isa('Actor::Player')) {
			debug "Player Moved: " . $actor->name . " ($actor->{binID}) Level $actor->{lv} $sex_lut{$actor->{sex}} $jobs_lut{$actor->{jobID}} - ($coordsFrom{x}, $coordsFrom{y}) -> ($coordsTo{x}, $coordsTo{y})\n", "parseMsg";

		} elsif ($actor->isa('Actor::Monster')) {
			debug "Monster Moved: " . $actor->nameIdx . " - ($coordsFrom{x}, $coordsFrom{y}) -> ($coordsTo{x}, $coordsTo{y})\n", "parseMsg";

		} elsif ($actor->isa('Actor::Pet')) {
			debug "Pet Moved: " . $actor->nameIdx . " - ($coordsFrom{x}, $coordsFrom{y}) -> ($coordsTo{x}, $coordsTo{y})\n", "parseMsg";

		} elsif ($actor->isa('Actor::Portal')) {
			# This can never happen of course.
			debug "Portal Moved: " . $actor->nameIdx . " - ($coordsFrom{x}, $coordsFrom{y}) -> ($coordsTo{x}, $coordsTo{y})\n", "parseMsg";

		} elsif ($actor->isa('Actor::NPC')) {
			# Neither can this.
			debug "Monster Moved: " . $actor->nameIdx . " - ($coordsFrom{x}, $coordsFrom{y}) -> ($coordsTo{x}, $coordsTo{y})\n", "parseMsg";

		} else {
			debug "Unknown Actor Moved: " . $actor->nameIdx . " - ($coordsFrom{x}, $coordsFrom{y}) -> ($coordsTo{x}, $coordsTo{y})\n", "parseMsg";
		}

	} elsif ($args->{switch} eq "007C") {
		# Actor Spawned
		if ($actor->isa('Actor::Player')) {
			debug "Player Spawned: " . $actor->nameIdx . " $sex_lut{$actor->{sex}} $jobs_lut{$actor->{jobID}}\n", "parseMsg";
		} elsif ($actor->isa('Actor::Monster')) {
			debug "Monster Spawned: " . $actor->nameIdx . "\n", "parseMsg";
		} elsif ($actor->isa('NPC')) {
			debug "NPC Spawned: " . $actor->nameIdx . "\n", "parseMsg";
		} else {
			debug "Unknown Spawned: " . $actor->nameIdx . "\n", "parseMsg";
		}
	}
}

sub actor_info {
	my ($self, $args) = @_;
	changeToInGameState();

	debug "Received object info: $args->{name}\n", "parseMsg_presence/name", 2;

	my $player = $playersList->getByID($args->{ID});
	if ($player) {
		# This packet tells us the names of players who aren't in a guild, as opposed to 0195.
		$player->setName(bytesToString($args->{name}));
		message "Player Info: " . $player->nameIdx . "\n", "parseMsg_presence", 2;
		updatePlayerNameCache($player);
		Plugins::callHook('charNameUpdate', $player);
	}

	my $monster = $monstersList->getByID($args->{ID});
	if ($monster) {
		my $name = bytesToString($args->{name});
		debug "Monster Info: $name ($monster->{binID})\n", "parseMsg", 2;
		$monster->{name_given} = $name;
		if ($monsters_lut{$monster->{nameID}} eq "") {
			$monster->setName($name);
			$monsters_lut{$monster->{nameID}} = $name;
			updateMonsterLUT("$Settings::tables_folder/monsters.txt", $monster->{nameID}, $name);
		}
	}

	my $npc = $npcs{$args->{ID}};
	if ($npc) {
		$npc->setName(bytesToString($args->{name}));
		if ($config{debug} >= 2) {
			my $binID = binFind(\@npcsID, $args->{ID});
			debug "NPC Info: $npc->{name} ($binID)\n", "parseMsg", 2;
		}

		my $location = "$field{name} $npc->{pos}{x} $npc->{pos}{y}";
		if (!$npcs_lut{$location}) {
			$npcs_lut{$location} = $npc->{name};
			updateNPCLUT("$Settings::tables_folder/npcs.txt", $location, $npc->{name});
		}
	}

	my $pet = $pets{$args->{ID}};
	if ($pet) {
		my $name = bytesToString($args->{name});
		$pet->{name_given} = $name;
		$pet->setName($name);
		if ($config{debug} >= 2) {
			my $binID = binFind(\@petsID, $args->{ID});
			debug "Pet Info: $pet->{name_given} ($binID)\n", "parseMsg", 2;
		}
	}
}

sub actor_look_at {
	my ($self, $args) = @_;
	changeToInGameState();

	my $actor = Actor::get($args->{ID});
	$actor->{look}{head} = $args->{head};
	$actor->{look}{body} = $args->{body};
	debug $actor->nameString . " looks at $args->{body}, $args->{head}\n", "parseMsg";
}

sub actor_movement_interrupted {
	my ($self, $args) = @_;
	my %coords;
	$coords{x} = $args->{x};
	$coords{y} = $args->{y};

	my $actor = Actor::get($args->{ID});
	$actor->{pos} = {%coords};
	$actor->{pos_to} = {%coords};
	if ($actor->isa('Actor::You') || $actor->isa('Actor::Player')) {
		$actor->{sitting} = 0;
	}
	if ($actor->isa('Actor::You')) {
		debug "Movement interrupted, your coordinates: $coords{x}, $coords{y}\n", "parseMsg_move";
		AI::clear("move");
	}
	if ($char->{homunculus} && $char->{homunculus}{ID} eq $actor->{ID}) {
		AI::clear("move");
	}
}

sub actor_muted {
	my ($self, $args) = @_;

	my $ID = $args->{ID};
	my $duration = $args->{duration};
	if ($duration > 0) {
		$duration = 0xFFFFFFFF - $duration + 1;
		message TF("%s is muted for %d minutes\n", getActorName($ID), $duration), "parseMsg_statuslook", 2;
	} else {
		message TF("%s is no longer muted\n", getActorName($ID)), "parseMsg_statuslook", 2;
	}
}

sub actor_name_received {
	my ($self, $args) = @_;

	# FIXME: There is more to this packet than just party name and guild name.
	# This packet is received when you leave a guild
	# (with cryptic party and guild name fields, at least for now)
	my $player = $playersList->getByID($args->{ID});
	if (defined $player) {
		# Receive names of players who are in a guild.
		$player->setName(bytesToString($args->{name}));
		$player->{party}{name} = bytesToString($args->{partyName});
		$player->{guild}{name} = bytesToString($args->{guildName});
		$player->{guild}{title} = bytesToString($args->{guildTitle});
		updatePlayerNameCache($player);
		debug "Player Info: $player->{name} ($player->{binID})\n", "parseMsg_presence", 2;
		Plugins::callHook('charNameUpdate', $player);
	} else {
		debug "Player Info for " . unpack("V", $args->{ID}) .
			" (not on screen): " . bytesToString($args->{name}) . "\n",
			"parseMsg_presence/remote", 2;
	}
}

sub actor_status_active {
	my ($self, $args) = @_;

	my ($type, $ID, $flag) = @{$args}{qw(type ID flag)};

	my $skillName = (defined($skillsStatus{$type})) ? $skillsStatus{$type} : "Unknown $type";
	$args->{skillName} = $skillName;
	my $actor = Actor::get($ID);
	$args->{actor} = $actor;

	my ($name, $is) = getActorNames($ID, 0, 'are', 'is');
	if ($flag) {
		# Skill activated
		my $again = 'now';
		if ($actor) {
			$again = 'again' if $actor->{statuses}{$skillName};
			$actor->{statuses}{$skillName} = 1;
		}
		my $disp = status_string($actor, $skillName, $again);
		message $disp, "parseMsg_statuslook", $ID eq $accountID ? 1 : 2;

	} else {
		# Skill de-activated (expired)
		delete $actor->{statuses}{$skillName} if $actor;
		my $disp = status_string($actor, $skillName, 'no longer');
		message $disp, "parseMsg_statuslook", $ID eq $accountID ? 1 : 2;
	}
}

sub actor_trapped {
	my ($self, $args) = @_;
	# original comment was that ID is not a valid ID
	# but it seems to be, at least on eAthena/Freya
	my $actor = Actor::get($args->{ID});
	debug "$actor is trapped.\n";
}

sub area_spell {
	my ($self, $args) = @_;

	# Area effect spell; including traps!
	my $ID = $args->{ID};
	my $sourceID = $args->{sourceID};
	my $x = $args->{x};
	my $y = $args->{y};
	my $type = $args->{type};
	my $fail = $args->{fail};
	# graffiti message, might only be for one of these switches
	#my $message = unpack("Z80", substr($msg, 17, 80));

	$spells{$ID}{'sourceID'} = $sourceID;
	$spells{$ID}{'pos'}{'x'} = $x;
	$spells{$ID}{'pos'}{'y'} = $y;
	$spells{$ID}{'pos_to'}{'x'} = $x;
	$spells{$ID}{'pos_to'}{'y'} = $y;
	my $binID = binAdd(\@spellsID, $ID);
	$spells{$ID}{'binID'} = $binID;
	$spells{$ID}{'type'} = $type;
	if ($type == 0x81) {
		message TF("%s opened Warp Portal on (%d, %d)\n", getActorName($sourceID), $x, $y), "skill";
	}
	debug "Area effect ".getSpellName($type)." ($binID) from ".getActorName($sourceID)." appeared on ($x, $y)\n", "skill", 2;

	Plugins::callHook('packet_areaSpell', {
		fail => $fail,
		sourceID => $sourceID,
		type => $type,
		x => $x,
		y => $y
	});
}

sub area_spell_disappears {
	my ($self, $args) = @_;

	# The area effect spell with ID dissappears
	my $ID = $args->{ID};
	my $spell = $spells{$ID};
	debug "Area effect ".getSpellName($spell->{type})." ($spell->{binID}) from ".getActorName($spell->{sourceID})." disappeared from ($spell->{pos}{x}, $spell->{pos}{y})\n", "skill", 2;
	delete $spells{$ID};
	binRemove(\@spellsID, $ID);
}

sub arrow_equipped {
	my ($self, $args) = @_;
	return unless $args->{index};
	$char->{arrow} = $args->{index};

	my $invIndex = findIndex($char->{inventory}, "index", $args->{index});
	if ($invIndex ne "" && $char->{equipment}{arrow} != $char->{inventory}[$invIndex]) {
		$char->{equipment}{arrow} = $char->{inventory}[$invIndex];
		$char->{inventory}[$invIndex]{equipped} = 32768;
		$ai_v{temp}{waitForEquip}-- if $ai_v{temp}{waitForEquip};
		message TF("Arrow/Bullet equipped: %s (%d)\n", $char->{inventory}[$invIndex]{name}, $invIndex);
	}
}

sub arrow_none {
	my ($self, $args) = @_;
	
	my $type = $args->{type};
	if ($type == 0) {
		delete $char->{'arrow'};
		if ($config{'dcOnEmptyArrow'}) {
			$interface->errorDialog(T("Please equip arrow first."));
			quit();
		} else {
			error T("Please equip arrow first.\n");
		}
	} elsif ($type == 3) {
		debug "Arrow equipped\n";
	}
}

sub arrowcraft_list {
	my ($self, $args) = @_;

	my $newmsg;
	my $msg = $args->{RAW_MSG};
	my $msg_size = $args->{RAW_MSG_SIZE};
	$self->decrypt(\$newmsg, substr($msg, 4));
	$msg = substr($msg, 0, 4).$newmsg;
	
	undef @arrowCraftID;
	for (my $i = 4; $i < $msg_size; $i += 2) {
		my $ID = unpack("v1", substr($msg, $i, 2));
		my $index = findIndex($char->{inventory}, "nameID", $ID);
		binAdd(\@arrowCraftID, $index);
	}

	message T("Received Possible Arrow Craft List - type 'arrowcraft'\n");
}

sub attack_range {
	my ($self, $args) = @_;
	
	my $type = $args->{type};
	debug "Your attack range is: $type\n";
	$char->{attack_range} = $type;
	if ($config{attackDistanceAuto} && $config{attackDistance} != $type) {
		message TF("Autodetected attackDistance = %s\n", $type), "success";
		configModify('attackDistance', $type, 1);
		configModify('attackMaxDistance', $type, 1);
	}	
}

sub buy_result {
	my ($self, $args) = @_;
	if ($args->{fail} == 0) {
		message T("Buy completed.\n"), "success";
	} elsif ($args->{fail} == 1) {
		error T("Buy failed (insufficient zeny).\n");
	} elsif ($args->{fail} == 2) {
		error T("Buy failed (insufficient weight capacity).\n");
	} elsif ($args->{fail} == 3) {
		error T("Buy failed (too many different inventory items).\n");
	} else {
		error TF("Buy failed (failure code %s).\n", $args->{fail});
	}
}

sub card_merge_list {
	my ($self, $args) = @_;
	
	# You just requested a list of possible items to merge a card into
	# The RO client does this when you double click a card
	my $newmsg;
	my $msg = $args->{RAW_MSG};
	$self->decrypt(\$newmsg, substr($msg, 4));
	$msg = substr($msg, 0, 4).$newmsg;
	my ($len) = unpack("x2 v1", $msg);

	my $display;
	$display .= T("-----Card Merge Candidates-----\n");

	my $index;
	my $invIndex;
	for (my $i = 4; $i < $len; $i += 2) {
		$index = unpack("v1", substr($msg, $i, 2));
		$invIndex = findIndex($char->{inventory}, "index", $index);
		binAdd(\@cardMergeItemsID,$invIndex);
		$display .= "$invIndex $char->{inventory}[$invIndex]{name}\n";
	}

	$display .= "-------------------------------\n";
	message $display, "list";	
}

sub card_merge_status {
	my ($self, $args) = @_;
		
	# something about successful compound?
	my $item_index = $args->{item_index};
	my $card_index = $args->{card_index};
	my $fail = $args->{fail};

	if ($fail) {
		message T("Card merging failed\n");
	} else {
		my $item_invindex = findIndex($char->{inventory}, "index", $item_index);
		my $card_invindex = findIndex($char->{inventory}, "index", $card_index);
		message TF("%s has been successfully merged into %s\n", $char->{inventory}[$card_invindex]{name}, $char->{inventory}[$item_invindex]{name}), "success";

		# get the ID so we can pack this into the weapon cards
		my $nameID = $char->{inventory}[$card_invindex]{nameID};

		# remove one of the card
		my $item = $char->{inventory}[$card_invindex];
		$item->{amount} -= 1;
		if ($item->{amount} <= 0) {
			delete $char->{inventory}[$card_invindex];
		}

		# rename the slotted item now
		my $item = $char->{inventory}[$item_invindex];
		# put the card into the item
		# FIXME: this is unoptimized
		my $newcards;
		my $addedcard;
		for (my $i = 0; $i < 4; $i++) {
			my $card = substr($item->{cards}, $i*2, 2);
			if (unpack("v1", $card)) {
				$newcards .= $card;
			} elsif (!$addedcard) {
				$newcards .= pack("v1", $nameID);
				$addedcard = 1;
			} else {
				$newcards .= pack("v1", 0);
			}
		}
		$item->{cards} = $newcards;
		$item->{name} = itemName($item);
	}

	undef @cardMergeItemsID;
	undef $cardMergeIndex;	
}

sub cart_info {
	my ($self, $args) = @_;

	$cart{items} = $args->{items};
	$cart{items_max} = $args->{items_max};
	$cart{weight} = int($args->{weight} / 10);
	$cart{weight_max} = int($args->{weight_max} / 10);
	$cart{exists} = 1;
	debug "[cart_info] received.\n", "parseMsg";
}

sub cart_add_failed {
	my ($self, $args) = @_;

	my $reason;
	if ($args->{fail} == 0) {
		$reason = 'overweight';
	} elsif ($args->{fail} == 1) {
		$reason = 'too many items';
	} else {
		$reason = "Unknown code $args->{fail}";
	}
	error TF("Can't Add Cart Item (%s)\n", $reason);
}

sub cart_equip_list {
	my ($self, $args) = @_;
	
	# "0122" sends non-stackable item info
	# "0123" sends stackable item info
	my $newmsg;
	my $msg = $args->{RAW_MSG};
	my $msg_size = $args->{RAW_MSG_SIZE};
	$self->decrypt(\$newmsg, substr($msg, 4));
	$msg = substr($msg, 0, 4).$newmsg;

	for (my $i = 4; $i < $msg_size; $i += 20) {
		my $index = unpack("v1", substr($msg, $i, 2));
		my $ID = unpack("v1", substr($msg, $i+2, 2));
		my $type = unpack("C1",substr($msg, $i+4, 1));
		my $item = $cart{inventory}[$index] = {};
		$item->{nameID} = $ID;
		$item->{amount} = 1;
		$item->{index} = $index;
		$item->{identified} = unpack("C1", substr($msg, $i+5, 1));
		$item->{type_equip} = unpack("v1", substr($msg, $i+6, 2));
		$item->{broken} = unpack("C1", substr($msg, $i+10, 1));
		$item->{upgrade} = unpack("C1", substr($msg, $i+11, 1));
		$item->{cards} = substr($msg, $i+12, 8);
		$item->{name} = itemName($item);

		debug "Non-Stackable Cart Item: $item->{name} ($index) x 1\n", "parseMsg";
		Plugins::callHook('packet_cart', {index => $index});
	}

	$ai_v{'inventory_time'} = time + 1;
	$ai_v{'cart_time'} = time + 1;	
}

sub cart_item_added {
	my ($self, $args) = @_;

	my $item = $cart{inventory}[$args->{index}] ||= {};
	if ($item->{amount}) {
		$item->{amount} += $args->{amount};
	} else {
		$item->{index} = $args->{index};
		$item->{nameID} = $args->{ID};
		$item->{amount} = $args->{amount};
		$item->{identified} = $args->{identified};
		$item->{broken} = $args->{broken};
		$item->{upgrade} = $args->{upgrade};
		$item->{cards} = $args->{cards};
		$item->{name} = itemName($item);
	}
	message TF("Cart Item Added: %s (%d) x %s\n", $item->{name}, $args->{index}, $args->{amount});
	$itemChange{$item->{name}} += $args->{amount};
	$args->{item} = $item;
}

sub cart_items_list {
	my ($self, $args) = @_;
	
	my $newmsg;
	my $msg = $args->{RAW_MSG};
	my $msg_size = $args->{RAW_MSG_SIZE};
	my $switch = $args->{switch};
	
	$self->decrypt(\$newmsg, substr($msg, 4));
	$msg = substr($msg, 0, 4).$newmsg;
	my $psize = ($switch eq "0123") ? 10 : 18;

	for (my $i = 4; $i < $msg_size; $i += $psize) {
		my $index = unpack("v1", substr($msg, $i, 2));
		my $ID = unpack("v1", substr($msg, $i+2, 2));
		my $amount = unpack("v1", substr($msg, $i+6, 2));

		my $item = $cart{inventory}[$index] ||= {};
		if ($item->{amount}) {
			$item->{amount} += $amount;
		} else {
			$item->{index} = $index;
			$item->{nameID} = $ID;
			$item->{amount} = $amount;
			$item->{cards} = substr($msg, $i + 10, 8) if ($psize == 18);
			$item->{name} = itemName($item);
			$item->{identified} = 1;
		}
		debug "Stackable Cart Item: $item->{name} ($index) x $amount\n", "parseMsg";
		Plugins::callHook('packet_cart', {index => $index});
	}

	$ai_v{'inventory_time'} = time + 1;
	$ai_v{'cart_time'} = time + 1;
	
}

sub combo_delay {
	my ($self, $args) = @_;

	$char->{combo_packet} = ($args->{delay}); #* 15) / 100000;
	# How was the above formula derived? I think it's better that the manipulation be
	# done in functions.pl (or whatever sub that handles this) instead of here.

	$args->{actor} = Actor::get($args->{ID});
	my $verb = $args->{actor}->verb('have', 'has');
	debug "$args->{actor} $verb combo delay $args->{delay}\n", "parseMsg_comboDelay";
}

sub cart_item_removed {
	my ($self, $args) = @_;

	my ($index, $amount) = @{$args}{qw(index amount)};

	my $item = $cart{inventory}[$index];
	$item->{amount} -= $amount;
	message TF("Cart Item Removed: %s (%d) x %s\n", $item->{name}, $index, $amount);
	$itemChange{$item->{name}} -= $amount;
	if ($item->{amount} <= 0) {
		$cart{'inventory'}[$index] = undef;
	}
	$args->{item} = $item;
}

sub change_to_constate25 {
	$net->setState(2.5);
	undef $accountID;
}

sub changeToInGameState {
	$net->setState(Network::IN_GAME) if ($net->getState() != 4 && $net->version == 1);
}

sub character_creation_failed {
	message T("Character creation failed. " . 
		"If you didn't make any mistake, then the name you chose already exists.\n"), "info";
	if (charSelectScreen() == 1) {
		$net->setState(3);
		$firstLoginMap = 1;
		$startingZenny = $chars[$config{'char'}]{'zenny'} unless defined $startingZenny;
		$sentWelcomeMessage = 1;
	}
}

sub character_creation_successful {
	my ($self, $args) = @_;
	
	my $char = new Actor::You;
	$char->{ID} = $args->{ID};
	$char->{name} = bytesToString($args->{name});
	$char->{zenny} = $args->{zenny};
	$char->{jobID} = 0;
	$char->{str} = $args->{str};
	$char->{agi} = $args->{agi};
	$char->{vit} = $args->{vit};
	$char->{int} = $args->{int};
	$char->{dex} = $args->{dex};
	$char->{luk} = $args->{luk};
	my $slot = $args->{slot};

	$char->{lv} = 1;
	$char->{lv_job} = 1;
	$char->{sex} = $accountSex2;
	$chars[$slot] = $char;

	$net->setState(3);
	message TF("Character %s (%d) created.\n", $char->{name}, $slot), "info";
	if (charSelectScreen() == 1) {
		$firstLoginMap = 1;
		$startingZenny = $chars[$config{'char'}]{'zenny'} unless defined $startingZenny;
		$sentWelcomeMessage = 1;
	}
}

sub character_deletion_successful {
	if (defined $AI::temp::delIndex) {
		message TF("Character %s (%d) deleted.\n", $chars[$AI::temp::delIndex]{name}, $AI::temp::delIndex), "info";
		delete $chars[$AI::temp::delIndex];
		undef $AI::temp::delIndex;
		for (my $i = 0; $i < @chars; $i++) {
			delete $chars[$i] if ($chars[$i] && !scalar(keys %{$chars[$i]}))
		}
	} else {
		message T("Character deleted.\n"), "info";
	}

	if (charSelectScreen() == 1) {
		$net->setState(3);
		$firstLoginMap = 1;
		$startingZenny = $chars[$config{'char'}]{'zenny'} unless defined $startingZenny;
		$sentWelcomeMessage = 1;
	}
}

sub character_deletion_failed {
	error T("Character cannot be deleted. Your e-mail address was probably wrong.\n");
	undef $AI::temp::delIndex;
	if (charSelectScreen() == 1) {
		$net->setState(3);
		$firstLoginMap = 1;
		$startingZenny = $chars[$config{'char'}]{'zenny'} unless defined $startingZenny;
		$sentWelcomeMessage = 1;
	}
}

sub character_moves {
	my ($self, $args) = @_;

	changeToInGameState();
	makeCoords($char->{pos}, substr($args->{RAW_MSG}, 6, 3));
	makeCoords2($char->{pos_to}, substr($args->{RAW_MSG}, 8, 3));
	my $dist = sprintf("%.1f", distance($char->{pos}, $char->{pos_to}));
	debug "You're moving from ($char->{pos}{x}, $char->{pos}{y}) to ($char->{pos_to}{x}, $char->{pos_to}{y}) - distance $dist, unknown $args->{unknown}\n", "parseMsg_move";
	$char->{time_move} = time;
	$char->{time_move_calc} = distance($char->{pos}, $char->{pos_to}) * ($char->{walk_speed} || 0.12);

	# Correct the direction in which we're looking
	my (%vec, $degree);
	getVector(\%vec, $char->{pos_to}, $char->{pos});
	$degree = vectorToDegree(\%vec);
	if (defined $degree) {
		my $direction = int sprintf("%.0f", (360 - $degree) / 45);
		$char->{look}{body} = $direction & 0x07;
		$char->{look}{head} = 0;
	}

	# Ugly; AI code in network subsystem! This must be fixed.
	if (AI::action eq "mapRoute" && $config{route_escape_reachedNoPortal} && $dist eq "0.0"){
	   if (!$portalsID[0]) {
		if ($config{route_escape_shout} ne "" && !defined($timeout{ai_route_escape}{time})){
			sendMessage("c", $config{route_escape_shout});
		}
 	   	 $timeout{ai_route_escape}{time} = time;
	   	 AI::queue("escape");
	   }
	}
}

sub character_name {
	my ($self, $args) = @_;
	my $name; # Type: String

	$name = bytesToString($args->{name});
	debug "Character name received: $name\n";
}

sub character_status {
	my ($self, $args) = @_;
	
	if ($args->{ID} eq $accountID) {
		$char->{param1} = $args->{param1};
		$char->{param2} = $args->{param2};
		$char->{param3} = $args->{param3};
	}

	setStatus(Actor::get($args->{ID}), $args->{param1}, $args->{param2}, $args->{param3});
}

sub chat_created {
	my ($self, $args) = @_;

	$currentChatRoom = $accountID;
	$chatRooms{$accountID} = {%createdChatRoom};
	binAdd(\@chatRoomsID, $accountID);
	binAdd(\@currentChatRoomUsers, $char->{name});
	message T("Chat Room Created\n");
}

sub chat_info {
	my ($self, $args) = @_;

	my $title;
	$self->decrypt(\$title, $args->{title});
	$title = bytesToString($title);

	my $chat = $chatRooms{$args->{ID}};
	if (!$chat || !%{$chat}) {
		$chat = $chatRooms{$args->{ID}} = {};
		binAdd(\@chatRoomsID, $args->{ID});
	}
	$chat->{title} = $title;
	$chat->{ownerID} = $args->{ownerID};
	$chat->{limit} = $args->{limit};
	$chat->{public} = $args->{public};
	$chat->{num_users} = $args->{num_users};
}

sub chat_join_result {
	my ($self, $args) = @_;
	
	if ($args->{type} == 1) {
		message T("Can't join Chat Room - Incorrect Password\n");
	} elsif ($args->{type} == 2) {
		message T("Can't join Chat Room - You're banned\n");
	}
}

sub chat_modified {
	my ($self, $args) = @_;
	
	my $title;
	$self->decrypt(\$title, $args->{title});
	$title = bytesToString($title);

	my ($ownerID, $ID, $limit, $public, $num_users) = @{$args}{qw(ownerID ID limit public num_users)};

	if ($ownerID eq $accountID) {
		$chatRooms{new}{title} = $title;
		$chatRooms{new}{ownerID} = $ownerID;
		$chatRooms{new}{limit} = $limit;
		$chatRooms{new}{public} = $public;
		$chatRooms{new}{num_users} = $num_users;
	} else {
		$chatRooms{$ID}{title} = $title;
		$chatRooms{$ID}{ownerID} = $ownerID;
		$chatRooms{$ID}{limit} = $limit;
		$chatRooms{$ID}{public} = $public;
		$chatRooms{$ID}{num_users} = $num_users;
	}
	message T("Chat Room Properties Modified\n");
}

sub chat_newowner {
	my ($self, $args) = @_;

	my $user = bytesToString($args->{user});
	if ($args->{type} == 0) {
		if ($user eq $char->{name}) {
			$chatRooms{$currentChatRoom}{ownerID} = $accountID;
		} else {
			my $players = $playersList->getItems();
			my $player;
			foreach my $p (@{$players}) {
				if ($p->{name} eq $user) {
					$player = $p;
					last;
				}
			}

			if ($player) {
				my $key = $player->{ID};
				$chatRooms{$currentChatRoom}{ownerID} = $key;
			}
		}
		$chatRooms{$currentChatRoom}{users}{$user} = 2;
	} else {
		$chatRooms{$currentChatRoom}{users}{$user} = 1;
	}
}

sub chat_user_join {
	my ($self, $args) = @_;

	my $user = bytesToString($args->{user});
	if ($currentChatRoom ne "") {
		binAdd(\@currentChatRoomUsers, $user);
		$chatRooms{$currentChatRoom}{users}{$user} = 1;
		$chatRooms{$currentChatRoom}{num_users} = $args->{num_users};
		message TF("%s has joined the Chat Room\n", $user);
	}
}

sub chat_user_leave {
	my ($self, $args) = @_;

	my $user = bytesToString($args->{user});
	delete $chatRooms{$currentChatRoom}{users}{$user};
	binRemove(\@currentChatRoomUsers, $user);
	$chatRooms{$currentChatRoom}{num_users} = $args->{num_users};
	if ($user eq $char->{name}) {
		binRemove(\@chatRoomsID, $currentChatRoom);
		delete $chatRooms{$currentChatRoom};
		undef @currentChatRoomUsers;
		$currentChatRoom = "";
		message T("You left the Chat Room\n");
	} else {
		message TF("%s has left the Chat Room\n", $user);
	}
}

sub chat_users {
	my ($self, $args) = @_;

	my $newmsg;
	$self->decrypt(\$newmsg, substr($args->{RAW_MSG}, 8));
	my $msg = substr($args->{RAW_MSG}, 0, 8).$newmsg;

	my $ID = substr($args->{RAW_MSG},4,4);
	$currentChatRoom = $ID;

	my $chat = $chatRooms{$currentChatRoom} ||= {};

	$chat->{num_users} = 0;
	for (my $i = 8; $i < $args->{RAW_MSG_SIZE}; $i += 28) {
		my $type = unpack("C1",substr($msg,$i,1));
		my ($chatUser) = unpack("Z*", substr($msg,$i + 4,24));
		$chatUser = bytesToString($chatUser);

		if ($chat->{users}{$chatUser} eq "") {
			binAdd(\@currentChatRoomUsers, $chatUser);
			if ($type == 0) {
				$chat->{users}{$chatUser} = 2;
			} else {
				$chat->{users}{$chatUser} = 1;
			}
			$chat->{num_users}++;
		}
	}

	message TF("You have joined the Chat Room %s\n", $chat->{title});
}

sub cast_cancelled {
	my ($self, $args) = @_;

	# Cast is cancelled
	my $ID = $args->{ID};

	my $source = Actor::get($ID);
	$source->{cast_cancelled} = time;
	my $skill = $source->{casting}->{skill};
	my $skillName = $skill ? $skill->getName() : 'Unknown';
	my $domain = ($ID eq $accountID) ? "selfSkill" : "skill";
	message TF("%s failed to cast %s\n", $source, $skillName), $domain;
	Plugins::callHook('packet_castCancelled', {
		sourceID => $ID
	});
	delete $source->{casting};
}

sub chat_removed {
	my ($self, $args) = @_;
	
	binRemove(\@chatRoomsID, $args->{ID});
	delete $chatRooms{ $args->{ID} };
}

sub deal_add_other {
	my ($self, $args) = @_;
	
	if ($args->{nameID} > 0) {
		my $item = $currentDeal{other}{ $args->{nameID} } ||= {};
		$item->{amount} += $args->{amount};
		$item->{nameID} = $args->{nameID};
		$item->{identified} = $args->{identified};
		$item->{broken} = $args->{broken};
		$item->{upgrade} = $args->{upgrade};
		$item->{cards} = $args->{cards};
		$item->{name} = itemName($item);
		message TF("%s added Item to Deal: %s x %s\n", $currentDeal{name}, $item->{name}, $args->{amount}), "deal";
	} elsif ($args->{amount} > 0) {
		$currentDeal{other_zenny} += $args->{amount};
		my $amount = formatNumber($args->{amount});
		message TF("%s added %s z to Deal\n", $currentDeal{name}, $amount), "deal";
	}
}

sub deal_add_you {
	my ($self, $args) = @_;

	if ($args->{fail} == 1) {
		error T("That person is overweight; you cannot trade.\n"), "deal";
		return;
	} elsif ($args->{fail} == 2) {
		error T("This item cannot be traded.\n"), "deal";
		return;
	} elsif ($args->{fail}) {
		error TF("You cannot trade (fail code %s).\n", $args->{fail}), "deal";
		return;
	}

	return unless $args->{index} > 0;

	my $invIndex = findIndex($char->{inventory}, 'index', $args->{index});
	my $item = $char->{inventory}[$invIndex];
	$currentDeal{you}{$item->{nameID}}{amount} += $currentDeal{lastItemAmount};
	$item->{amount} -= $currentDeal{lastItemAmount};
	message TF("You added Item to Deal: %s x %s\n", $item->{name}, $currentDeal{lastItemAmount}), "deal";
	$itemChange{$item->{name}} -= $currentDeal{lastItemAmount};
	$currentDeal{you_items}++;
	$args->{item} = $item;
	delete $char->{inventory}[$invIndex] if $item->{amount} <= 0;
}

sub deal_begin {
	my ($self, $args) = @_;
	
	if ($args->{type} == 0) {
		error T("That person is too far from you to trade.\n");
	} elsif ($args->{type} == 2) {
		error T("That person is in another deal.\n");
	} elsif ($args->{type} == 3) {
		if (%incomingDeal) {
			$currentDeal{name} = $incomingDeal{name};
			undef %incomingDeal;
		} else {
			my $ID = $outgoingDeal{ID};
			my $player;
			$player = $playersList->getByID($ID) if (defined $ID);
			$currentDeal{ID} = $ID;
			if ($player) {
				$currentDeal{name} = $player->{name};
			} else {
				$currentDeal{name} = 'Unknown #' . unpack("V", $ID);
			}
			undef %outgoingDeal;
		}
		message TF("Engaged Deal with %s\n", $currentDeal{name}), "deal";
	} else {
		error TF("Deal request failed (unknown error %s).\n", $args->{type});
	}
}

sub deal_cancelled {
	undef %incomingDeal;
	undef %outgoingDeal;
	undef %currentDeal;
	message T("Deal Cancelled\n"), "deal";
}

sub deal_complete {
	undef %outgoingDeal;
	undef %incomingDeal;
	undef %currentDeal;
	message T("Deal Complete\n"), "deal";
}

sub deal_finalize {
	my ($self, $args) = @_;
	if ($args->{type} == 1) {
		$currentDeal{other_finalize} = 1;
		message TF("%s finalized the Deal\n", $currentDeal{name}), "deal";

	} else {
		$currentDeal{you_finalize} = 1;
		# FIXME: shouldn't we do this when we actually complete the deal?
		$char->{zenny} -= $currentDeal{you_zenny};
		message T("You finalized the Deal\n"), "deal";
	}
}

sub deal_request {
	my ($self, $args) = @_;
	my $level = $args->{level} || 'Unknown';
	my $user = bytesToString($args->{user});

	$incomingDeal{name} = $user;
	$timeout{ai_dealAutoCancel}{time} = time;
	message TF("%s (level %s) Requests a Deal\n", $user, $level), "deal";
	message T("Type 'deal' to start dealing, or 'deal no' to deny the deal.\n"), "deal";
}

sub devotion {
	my ($self, $args) = @_;

	my $source = Actor::get($args->{sourceID});
	my $msg = '';

	for (my $i = 0; $i < 5; $i++) {
		my $ID = substr($args->{data}, $i*4, 4);
		last if unpack("V", $ID) == 0;

		my $actor = Actor::get($ID);
		$msg .= skillUseNoDamage_string($source, $actor, 0, 'devotion');
	}

	message "$msg";
}

sub egg_list {
	my ($self, $args) = @_;
	message T("-----Egg Hatch Candidates-----\n"), "list";
	for (my $i = 4; $i < $args->{RAW_MSG_SIZE}; $i += 2) {
		my $index = unpack("v1", substr($args->{RAW_MSG}, $i, 2));
		my $invIndex = findIndex($char->{inventory}, "index", $index);
		message "$invIndex $char->{inventory}[$invIndex]{name}\n", "list";
	}
	message "------------------------------\n", "list";
}

sub emoticon {
	my ($self, $args) = @_;
	my $emotion = $emotions_lut{$args->{type}}{display} || "<emotion #$args->{type}>";
	
	if ($args->{ID} eq $accountID) {
		message "$char->{name}: $emotion\n", "emotion";
		chatLog("e", "$char->{name}: $emotion\n") if (existsInList($config{'logEmoticons'}, $args->{type}) || $config{'logEmoticons'} eq "all");
		
	} elsif (my $player = $playersList->getByID($args->{ID})) {
		my $name = $player->name;

		#my $dist = "unknown";
		my $dist = distance($char->{pos_to}, $player->{pos_to});
		$dist = sprintf("%.1f", $dist) if ($dist =~ /\./);

		# Translation Comment: "[dist=$dist] $name ($player->{binID}): $emotion\n"
		message TF("[dist=%s] %s (%d): %s\n", $dist, $name, $player->{binID}, $emotion), "emotion";
		chatLog("e", "$name".": $emotion\n") if (existsInList($config{'logEmoticons'}, $args->{type}) || $config{'logEmoticons'} eq "all");

		my $index = AI::findAction("follow");
		if ($index ne "") {
			my $masterID = AI::args($index)->{ID};
			if ($config{'followEmotion'} && $masterID eq $args->{ID} &&
			       distance($char->{pos_to}, $player->{pos_to}) <= $config{'followEmotion_distance'})
			{
				my %args = ();
				$args{timeout} = time + rand (1) + 0.75;

				if ($args->{type} == 30) {
					$args{emotion} = 31;
				} elsif ($args->{type} == 31) {
					$args{emotion} = 30;
				} else {
					$args{emotion} = $args->{type};
				}

				AI::queue("sendEmotion", \%args);
			}
		}
	} elsif (my $monster = $monstersList->getByID($args->{ID})) {
		my $dist = distance($char->{pos_to}, $monster->{pos_to});
		$dist = sprintf("%.1f", $dist) if ($dist =~ /\./);

		# Translation Comment: "[dist=$dist] $monster->name ($monster->{binID}): $emotion\n"
		message TF("[dist=%s] Monster %s (%d): %s\n", $dist, $monster->name, $monster->{binID}, $emotion), "emotion";
		
	} else {
		my $actor = Actor::get($args->{ID});
		my $name = $actor->name;

		my $dist = "unknown";
		if (!$actor->isa('Actor::Unknown')) {
			$dist = distance($char->{pos_to}, $actor->{pos_to});
			$dist = sprintf("%.1f", $dist) if ($dist =~ /\./);
		}
		
		message TF("[dist=%s] %s: %s\n", $dist, $actor->nameIdx, $emotion), "emotion";
		chatLog("e", "$name".": $emotion\n") if (existsInList($config{'logEmoticons'}, $args->{type}) || $config{'logEmoticons'} eq "all");
	}
}

sub equip_item {
	my ($self, $args) = @_;
	my $invIndex = findIndex($char->{inventory}, "index", $args->{index});
	my $item = $char->{inventory}[$invIndex];
	if (!$args->{success}) {
		message TF("You can't put on %s (%d)\n", $item->{name}, $invIndex);
	} else {
		$item->{equipped} = $args->{type};
		if ($args->{type} == 10) {
			$char->{equipment}{arrow} = $item;
		} else {
			foreach (%equipSlot_rlut){
				if ($_ & $args->{type}){
					next if $_ == 10; # work around Arrow bug
					$char->{equipment}{$equipSlot_lut{$_}} = $item;
				}
			}
		}
		message TF("You equip %s (%d) - %s (type %s)\n", $item->{name}, $invIndex, $equipTypes_lut{$item->{type_equip}}, $args->{type}), 'inventory';
	}
	$ai_v{temp}{waitForEquip}-- if $ai_v{temp}{waitForEquip};
}

sub errors {
	my ($self, $args) = @_;

	Plugins::callHook('disconnected') if ($net->getState() == Network::IN_GAME);
	if ($net->getState() == Network::IN_GAME &&
		($config{dcOnDisconnect} > 1 ||
		($config{dcOnDisconnect} &&
		$args->{type} != 3 &&
		$args->{type} != 10))) {
		message T("Lost connection; exiting\n");
		$quit = 1;
	}

	$net->setState(1);
	undef $conState_tries;

	$timeout_ex{'master'}{'time'} = time;
	$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
	if (($args->{type} != 0)) {
		$net->serverDisconnect();
	}
	if ($args->{type} == 0) {
		error T("Server shutting down\n"), "connection";
	} elsif ($args->{type} == 1) {
		error T("Error: Server is closed\n"), "connection";
	} elsif ($args->{type} == 2) {
		if ($config{'dcOnDualLogin'} == 1) {
			$interface->errorDialog(TF("Critical Error: Dual login prohibited - Someone trying to login!\n\n" .
				"%s will now immediately disconnect.", $Settings::NAME));
			$quit = 1;
		} elsif ($config{'dcOnDualLogin'} >= 2) {
			error T("Critical Error: Dual login prohibited - Someone trying to login!\n"), "connection";
			message TF("Disconnect for %s seconds...\n", $config{'dcOnDualLogin'}), "connection";
			$timeout_ex{'master'}{'timeout'} = $config{'dcOnDualLogin'};
		} else {
			error T("Critical Error: Dual login prohibited - Someone trying to login!\n"), "connection";
		}

	} elsif ($args->{type} == 3) {
		error T("Error: Out of sync with server\n"), "connection";
	} elsif ($args->{type} == 4) {
		error T("Error: Server is jammed due to over-population.\n"), "connection";
	} elsif ($args->{type} == 5) {
		error T("Error: You are underaged and cannot join this server.\n"), "connection";
	} elsif ($args->{type} == 6) {
		$interface->errorDialog(T("Critical Error: You must pay to play this account!\n"));
		$quit = 1 unless ($net->version == 1);
	} elsif ($args->{type} == 8) {
		error T("Error: The server still recognizes your last connection\n"), "connection";
	} elsif ($args->{type} == 9) {
		error T("Error: IP capacity of this Internet Cafe is full. Would you like to pay the personal base?\n"), "connection";
	} elsif ($args->{type} == 10) {
		error T("Error: You are out of available time paid for\n"), "connection";
	} elsif ($args->{type} == 15) {
		error T("Error: You have been forced to disconnect by a GM\n"), "connection";
	} else {
		error TF("Unknown error %s\n", $args->{type}), "connection";
	}
}

sub exp_zeny_info {
	my ($self, $args) = @_;
	changeToInGameState();

	if ($args->{type} == 1) {
		$char->{exp_last} = $char->{exp};
		$char->{exp} = $args->{val};
		debug "Exp: $args->{val}\n", "parseMsg";
		if (!$bExpSwitch) {
			$bExpSwitch = 1;
		} else {
			if ($char->{exp_last} > $char->{exp}) {
				$monsterBaseExp = 0;
			} else {
				$monsterBaseExp = $char->{exp} - $char->{exp_last};
			}
			$totalBaseExp += $monsterBaseExp;
			if ($bExpSwitch == 1) {
				$totalBaseExp += $monsterBaseExp;
				$bExpSwitch = 2;
			}
		}

	} elsif ($args->{type} == 2) {
		$char->{exp_job_last} = $char->{exp_job};
		$char->{exp_job} = $args->{val};
		debug "Job Exp: $args->{val}\n", "parseMsg";
		if ($jExpSwitch == 0) {
			$jExpSwitch = 1;
		} else {
			if ($char->{exp_job_last} > $char->{exp_job}) {
				$monsterJobExp = 0;
			} else {
				$monsterJobExp = $char->{exp_job} - $char->{exp_job_last};
			}
			$totalJobExp += $monsterJobExp;
			if ($jExpSwitch == 1) {
				$totalJobExp += $monsterJobExp;
				$jExpSwitch = 2;
			}
		}
		my $basePercent = $char->{exp_max} ?
			($monsterBaseExp / $char->{exp_max} * 100) :
			0;
		my $jobPercent = $char->{exp_job_max} ?
			($monsterJobExp / $char->{exp_job_max} * 100) :
			0;
		message TF("Exp gained: %d/%d (%.2f%%/%.2f%%)\n", $monsterBaseExp, $monsterJobExp, $basePercent, $jobPercent), "exp";

	} elsif ($args->{type} == 20) {
		my $change = $args->{val} - $char->{zenny};
		if ($change > 0) {
			message TF("You gained %s zeny.\n", formatNumber($change));
		} elsif ($change < 0) {
			message TF("You lost %s zeny.\n", formatNumber(-$change));
			if ($config{dcOnZeny} && $args->{val} <= $config{dcOnZeny}) {
				$interface->errorDialog(TF("Disconnecting due to zeny lower than %s.", $config{dcOnZeny}));
				$quit = 1;
			}
		}
		$char->{zenny} = $args->{val};
		debug "Zenny: $args->{val}\n", "parseMsg";
	} elsif ($args->{type} == 22) {
		$char->{exp_max_last} = $char->{exp_max};
		$char->{exp_max} = $args->{val};
		debug(TF("Required Exp: %s\n", $args->{val}), "parseMsg");
		if (!$net->clientAlive() && $initSync && $config{serverType} == 2) {
			$messageSender->sendSync(1);
			$initSync = 0;
		}
	} elsif ($args->{type} == 23) {
		$char->{exp_job_max_last} = $char->{exp_job_max};
		$char->{exp_job_max} = $args->{val};
		debug("Required Job Exp: $args->{val}\n", "parseMsg");
		message TF("BaseExp: %s | JobExp: %s\n", $monsterBaseExp, $monsterJobExp), "info", 2 if ($monsterBaseExp);
	}
}

sub forge_list {
	my ($self, $args) = @_;
	
	message T("========Forge List========\n");
	for (my $i = 4; $i < $args->{RAW_MSG_SIZE}; $i += 8) {
		my $viewID = unpack("v1", substr($args->{RAW_MSG}, $i, 2));
		message "$viewID $items_lut{$viewID}\n";
		# always 0x0012
		#my $unknown = unpack("v1", substr($args->{RAW_MSG}, $i+2, 2));
		# ???
		#my $charID = substr($args->{RAW_MSG}, $i+4, 4);
	}
	message "=========================\n";
}

sub friend_list {
	my ($self, $args) = @_;

	# Friend list
	undef @friendsID;
	undef %friends;
	my $msg = $args->{RAW_MSG};
	my $msg_size = $args->{RAW_MSG_SIZE};

	my $ID = 0;
	for (my $i = 4; $i < $msg_size; $i += 32) {
		binAdd(\@friendsID, $ID);
		$friends{$ID}{'accountID'} = substr($msg, $i, 4);
		$friends{$ID}{'charID'} = substr($msg, $i + 4, 4);
		$friends{$ID}{'name'} = bytesToString(unpack("Z24", substr($msg, $i + 8 , 24)));
		$friends{$ID}{'online'} = 0;
		$ID++;
	}
}

sub friend_logon {
	my ($self, $args) = @_;

	# Friend In/Out
	my $friendAccountID = $args->{friendAccountID};
	my $friendCharID = $args->{friendCharID};
	my $isNotOnline = $args->{isNotOnline};

	for (my $i = 0; $i < @friendsID; $i++) {
		if ($friends{$i}{'accountID'} eq $friendAccountID && $friends{$i}{'charID'} eq $friendCharID) {
			$friends{$i}{'online'} = 1 - $isNotOnline;
			if ($isNotOnline) {
				message TF("Friend %s has disconnected\n", $friends{$i}{name}), undef, 1;
			} else {
				message TF("Friend %s has connected\n", $friends{$i}{name}), undef, 1;
			}
			last;
		}
	}	
}

sub friend_request {
	my ($self, $args) = @_;
	
	# Incoming friend request
	$incomingFriend{'accountID'} = $args->{accountID};
	$incomingFriend{'charID'} = $args->{charID};
	$incomingFriend{'name'} = bytesToString($args->{name});
	message TF("%s wants to be your friend\n", $incomingFriend{'name'});
	message TF("Type 'friend accept' to be friend with %s, otherwise type 'friend reject'\n", $incomingFriend{'name'});
}

sub friend_removed {
	my ($self, $args) = @_;

	# Friend removed
	my $friendAccountID =  $args->{friendAccountID};
	my $friendCharID =  $args->{friendCharID};
	for (my $i = 0; $i < @friendsID; $i++) {
		if ($friends{$i}{'accountID'} eq $friendAccountID && $friends{$i}{'charID'} eq $friendCharID) {
			message TF("%s is no longer your friend\n", $friends{$i}{'name'});
			binRemove(\@friendsID, $i);
			delete $friends{$i};
			last;
		}
	}	
}

sub friend_response {
	my ($self, $args) = @_;
		
	# Response to friend request
	my $type = $args->{type};
	my $name = bytesToString($args->{name});
	if ($type) {
		message TF("%s rejected to be your friend\n", $name);
	} else {
		my $ID = @friendsID;
		binAdd(\@friendsID, $ID);
		$friends{$ID}{'accountID'} = substr($msg, 4, 4);
		$friends{$ID}{'charID'} = substr($msg, 8, 4);
		$friends{$ID}{'name'} = $name;
		$friends{$ID}{'online'} = 1;
		message TF("%s is now your friend\n", $incomingFriend{'name'});
	}	
}

sub homunculus_food {
	my ($self, $args) = @_;
	if ($args->{success}) {
		message TF("Fed homunculus with %s\n", itemNameSimple($args->{foodID})), "homunculus";
	} else {
		error TF("Failed to feed homunculus with %s: no food in inventory.\n", itemNameSimple($args->{foodID})), "homunculus";
		# auto-vaporize
		if ($char->{homunculus}{hunger} <= 11 && timeOut($char->{homunculus}{vaporize_time}, 5)) {
			$messageSender->sendSkillUse(244, 1, $accountID);
			$char->{homunculus}{vaporize_time} = time;
			error "Critical hunger level reached. Homunculus is put to rest.\n", "homunculus";
		}
	}
}

sub homunculus_info {
	my ($self, $args) = @_;
	if ($args->{type} == 0) {
		my $state = $char->{homunculus}{state}
			if ($char->{homunculus} && $char->{homunculus}{ID} && $char->{homunculus}{ID} ne $args->{ID});
		$char->{homunculus} = Actor::get($args->{ID});
		$char->{homunculus}{state} = $state if (defined $state);
		$char->{homunculus}{map} = $field{name};
	} elsif ($args->{type} == 1) {
		$char->{homunculus}{intimacy} = $args->{val};
	} elsif ($args->{type} == 2) {
		$char->{homunculus}{hunger} = $args->{val};
	}
}

sub homunculus_skills {
	my ($self, $args) = @_;

	# Character skill list
	changeToInGameState();
	my $newmsg;
	my $msg = $args->{RAW_MSG};
	my $msg_size = $args->{RAW_MSG_SIZE};
	
	undef @AI::Homunculus::homun_skillsID;
	for (my $i = 4; $i < $msg_size; $i += 37) {
		my $skillID = unpack("v1", substr($msg, $i, 2));
		# target type is 0 for novice skill, 1 for enemy, 2 for place, 4 for immediate invoke, 16 for party member
		my $targetType = unpack("v1", substr($msg, $i+2, 2)); # we don't use this yet
		my $level = unpack("v1", substr($msg, $i + 6, 2));
		my $sp = unpack("v1", substr($msg, $i + 8, 2));
		my $range = unpack("v1", substr($msg, $i + 10, 2));
		my ($handle) = unpack("Z*", substr($msg, $i + 12, 24));
		my $up = unpack("C1", substr($msg, $i+36, 1));
		if (!$handle) {
			$handle = Skill->new(idn => $skillID)->getHandle();
		}

		$char->{skills}{$handle}{ID} = $skillID;
		$char->{skills}{$handle}{sp} = $sp;
		$char->{skills}{$handle}{range} = $range;
		$char->{skills}{$handle}{up} = $up;
		$char->{skills}{$handle}{targetType} = $targetType;
		if (!$char->{skills}{$handle}{lv}) {
			$char->{skills}{$handle}{lv} = $level;
		}
		binAdd(\@AI::Homunculus::homun_skillsID, $handle) if (!binFind(\@AI::Homunculus::homun_skillsID, $handle));
		Skill::DynamicInfo::add($skillID, $handle, $level, $sp, $range, $targetType, Skill::OWNER_HOMUN);

		Plugins::callHook('packet_homunSkills', {
			ID => $skillID,
			handle => $handle,
			level => $level,
		});
	}
}

sub homunculus_stats {
	my ($self, $args) = @_;
	my $homunculus = $char->{homunculus};
	$homunculus->{name} = $args->{name};

	# Homunculus states:
	# 0 - alive
	# 2 - rest
	# 4 - dead

	if (($args->{state} & ~8) > 1) {
		foreach my $handle (@AI::Homunculus::homun_skillsID) {
			delete $char->{skills}{$handle};
		}
		AI::Homunculus::clear();
		undef @AI::Homunculus::homun_skillsID;
		if ($homunculus->{state} != $args->{state}) {
			if ($args->{state} & 2) {
				message T("Your Homunculus was vaporized!\n"), 'homunculus';
			} elsif ($args->{state} & 4) {
				message T("Your Homunculus died!\n"), 'homunculus';
			}
		}
	} elsif ($homunculus->{state} != $args->{state}) {
		if ($homunculus->{state} & 2) {
			message T("Your Homunculus was recalled!\n"), 'homunculus';
		} elsif ($char->{homunculus}{state} & 4) {
			message T("Your Homunculus was resurrected!\n"), 'homunculus';
		}
	}

	$homunculus->{state}     = $args->{state};
	$homunculus->{level}     = $args->{lvl};
	$homunculus->{hunger}    = $args->{hunger};
	$homunculus->{intimacy}  = $args->{intimacy};
	$homunculus->{accessory} = $args->{accessory};
	$homunculus->{atk}       = $args->{atk};
	$homunculus->{matk}      = $args->{matk};
	$homunculus->{hit}       = $args->{hit};
	$homunculus->{critical}  = $args->{critical};
	$homunculus->{def}       = $args->{def};
	$homunculus->{mdef}      = $args->{mdef};
	$homunculus->{flee}      = $args->{flee};
	$homunculus->{aspd}      = $args->{aspd};
	$homunculus->{aspdDisp}  = int (200 - (($args->{aspd} < 10) ? 10 : ($args->{aspd} / 10)));
	$homunculus->{hp}        = $args->{hp};
	$homunculus->{hp_max}    = $args->{hp_max};
	$homunculus->{sp}        = $args->{sp};
	$homunculus->{sp_max}    = $args->{sp_max};
	$homunculus->{exp}       = $args->{exp};
	$homunculus->{exp_max}   = $args->{exp_max};
	$homunculus->{hpPercent} = ($args->{hp} / $args->{hp_max}) * 100;
	$homunculus->{spPercent} = ($args->{sp} / $args->{sp_max}) * 100;
	$homunculus->{expPercent}   = ($args->{exp_max}) ? ($args->{exp} / $args->{exp_max}) * 100 : 0;
	$homunculus->{points_skill} = $args->{points_skill};
}

sub gameguard_grant {
	my ($self, $args) = @_;

	if ($args->{server} == 0) {
		error T("The server Denied the login because GameGuard packets where not replied " . 
			"correctly or too many time has been spent to send the response.\n" .
			"Please verify the version of your poseidon server and try again\n"), "poseidon";
		return;
	} elsif ($args->{server} == 1) {
		message T("Server granted login request to account server\n"), "poseidon";
	} else {
		message T("Server granted login request to char/map server\n"), "poseidon";
		change_to_constate25 if ($config{'gameGuard'} eq "2");
	}
	$net->setState(1.3) if ($net->getState() == 1.2);
}

sub gameguard_request {
	my ($self, $args) = @_;

	return if ($net->version == 1 && $config{gameGuard} ne '2');
	Poseidon::Client::getInstance()->query(
		substr($args->{RAW_MSG}, 0, $args->{RAW_MSG_SIZE})
	);
	debug "Querying Poseidon\n", "poseidon";
}

sub guild_allies_enemy_list {
	my ($self, $args) = @_;
	
	# Guild Allies/Enemy List
	# <len>.w (<type>.l <guildID>.l <guild name>.24B).*
	# type=0 Ally
	# type=1 Enemy

	# This is the length of the entire packet
	my $msg = $args->{RAW_MSG};
	my $len = unpack("v", substr($msg, 2, 2));

	# clear $guild{enemy} and $guild{ally} otherwise bot will misremember alliances -zdivpsa
	$guild{enemy} = $guild{ally} = {};

	for (my $i = 4; $i < $len; $i += 32) {
		my ($type, $guildID, $guildName) = unpack("V1 V1 Z24", substr($msg, $i, 32));
		$guildName = bytesToString($guildName);
		if ($type) {
			# Enemy guild
			$guild{enemy}{$guildID} = $guildName;
		} else {
			# Allied guild
			$guild{ally}{$guildID} = $guildName;
		}
		debug "Your guild is ".($type ? 'enemy' : 'ally')." with guild $guildID ($guildName)\n", "guild";
	}
}

sub guild_ally_request {
	my ($self, $args) = @_;

	my $ID = $args->{ID}; # is this a guild ID or account ID? Freya calls it an account ID
	my $name = bytesToString($args->{name}); # Type: String

	message TF("Incoming Request to Ally Guild '%s'\n", $name);
	$incomingGuild{ID} = $ID;
	$incomingGuild{Type} = 2;
	$timeout{ai_guildAutoDeny}{time} = time;
}

sub guild_broken {
	my ($self, $args) = @_;
	# FIXME: determine the real significance of flag
	my $flag = $args->{flag};
	message T("Guild broken.\n");
	undef %{$char->{guild}};
	undef $char->{guildID};
	undef %guild;
}

sub guild_member_setting_list {
	my ($self, $args) = @_;
	my $newmsg;
	my $msg = $args->{RAW_MSG};
	my $msg_size = $args->{RAW_MSG_SIZE};
	$self->decrypt(\$newmsg, substr($msg, 4, length($msg)-4));
	$msg = substr($msg, 0, 4).$newmsg;
	my $gtIndex;
	for (my $i = 4; $i < $msg_size; $i += 16) {
		$gtIndex = unpack("V1", substr($msg, $i, 4));
		$guild{positions}[$gtIndex]{invite} = (unpack("C1", substr($msg, $i + 4, 1)) & 0x01) ? 1 : '';
		$guild{positions}[$gtIndex]{punish} = (unpack("C1", substr($msg, $i + 4, 1)) & 0x10) ? 1 : '';
		$guild{positions}[$gtIndex]{feeEXP} = unpack("V1", substr($msg, $i + 12, 4));
	}
}

sub guild_skills_list {
	my ($self, $args) = @_;
	my $msg = $args->{RAW_MSG};
	my $msg_size = $args->{RAW_MSG_SIZE};
	for (my $i = 6; $i < $msg_size; $i += 37) {
		my $skillID = unpack("v1", substr($msg, $i, 2));
		my $targetType = unpack("v1", substr($msg, $i+2, 2));
		my $level = unpack("v1", substr($msg, $i + 6, 2));
		my $sp = unpack("v1", substr($msg, $i + 8, 2));
		my ($skillName) = unpack("Z*", substr($msg, $i + 12, 24));
 
		my $up = unpack("C1", substr($msg, $i+36, 1));
		$guild{skills}{$skillName}{ID} = $skillID;
		$guild{skills}{$skillName}{sp} = $sp;
		$guild{skills}{$skillName}{up} = $up;
		$guild{skills}{$skillName}{targetType} = $targetType;
		if (!$guild{skills}{$skillName}{lv}) {
			$guild{skills}{$skillName}{lv} = $level;
		}
	}
}
 
sub guild_chat {
	my ($self, $args) = @_;
	my ($chatMsgUser, $chatMsg); # Type: String
	my $chat; # Type: String

	$chat = bytesToString($args->{message});
	if (($chatMsgUser, $chatMsg) = $chat =~ /(.*?) : (.*)/) {
		$chatMsgUser =~ s/ $//;
		stripLanguageCode(\$chatMsg);
		$chat = "$chatMsgUser : $chatMsg";
	}

	chatLog("g", "$chat\n") if ($config{'logGuildChat'});
	# Translation Comment: Guild Chat
	message TF("[Guild] %s\n", $chat), "guildchat";
	# Only queue this if it's a real chat message
	ChatQueue::add('g', 0, $chatMsgUser, $chatMsg) if ($chatMsgUser);

	Plugins::callHook('packet_guildMsg', {
		MsgUser => $chatMsgUser,
		Msg => $chatMsg
	});
}

sub guild_create_result {
	my ($self, $args) = @_;
	my $type = $args->{type};
	
	my %types = (
		0 => T("Guild create successful.\n"),
		2 => T("Guild create failed: Guild name already exists.\n"),
		3 => T("Guild create failed: Emperium is needed.\n")
	);
	if ($types{$type}) {
		message $types{$type};
	} else {
		message TF("Guild create: Unknown error %s\n", $type);
	}
}

sub guild_expulsionlist {
	my ($self, $args) = @_;

	for (my $i = 4; $i < $args->{RAW_MSG_SIZE}; $i += 88) {
		my ($name)  = unpack("Z24", substr($args->{'RAW_MSG'}, $i, 24));
		my $acc     = unpack("Z24", substr($args->{'RAW_MSG'}, $i + 24, 24));
		my ($cause) = unpack("Z44", substr($args->{'RAW_MSG'}, $i + 48, 44));
		$guild{expulsion}{$acc}{name} = bytesToString($name);
		$guild{expulsion}{$acc}{cause} = bytesToString($cause);
	}
}

sub guild_info {
	my ($self, $args) = @_;
	# Guild Info
	hashCopyByKey(\%guild, $args, qw(ID lvl conMember maxMember average exp next_exp members name master));
	$guild{members}++; # count ourselves in the guild members count
}

sub guild_invite_result {
	my ($self, $args) = @_;

	my $type = $args->{type};

	my %types = (
		0 => 'Target is already in a guild.',
		1 => 'Target has denied.',
		2 => 'Target has accepted.',
		3 => 'Your guild is full.'
	);
	if ($types{$type}) {
	    message TF("Guild join request: %s\n", $types{$type});
	} else {
	    message TF("Guild join request: Unknown %s\n", $type);
	}
}

sub guild_location {
	# FIXME: not implemented
	my ($self, $args) = @_;
}

sub guild_leave {
	my ($self, $args) = @_;
	
	message TF("%s has left the guild.\n" .
		"Reason: %s\n", $args->{name}, $args->{message}), "schat";	
}

sub guild_expulsion {
	my ($self, $args) = @_;
	
	message TF("%s has been removed from the guild.\n" .
		"Reason: %s\n", $args->{name}, $args->{message}), "schat";
}

sub guild_members_list {
	my ($self, $args) = @_;

	my $newmsg;
	my $jobID;
	my $msg = $args->{RAW_MSG};
	my $msg_size = $args->{RAW_MSG_SIZE};
	$self->decrypt(\$newmsg, substr($msg, 4, length($msg) - 4));
	$msg = substr($msg, 0, 4) . $newmsg;
	
	my $c = 0;
	delete $guild{member};
	for (my $i = 4; $i < $msg_size; $i+=104){
		$guild{member}[$c]{ID}    = substr($msg, $i, 4);
		$guild{member}[$c]{charID}	  = substr($msg, $i+4, 4);
		$jobID = unpack("v1", substr($msg, $i + 14, 2));
		if ($jobID =~ /^40/) {
			$jobID =~ s/^40/1/;
			$jobID += 60;
		}
		$guild{member}[$c]{jobID} = $jobID;
		$guild{member}[$c]{lvl}   = unpack("v1", substr($msg, $i + 16, 2));
		$guild{member}[$c]{contribution} = unpack("V1", substr($msg, $i + 18, 4));
		$guild{member}[$c]{online} = unpack("v1", substr($msg, $i + 22, 2));
		my $gtIndex = unpack("V1", substr($msg, $i + 26, 4));
		$guild{member}[$c]{title} = $guild{title}[$gtIndex];
		$guild{member}[$c]{name} = bytesToString(unpack("Z24", substr($msg, $i + 80, 24)));
		$c++;
	}
	
}

sub guild_member_online_status {
	my ($self, $args) = @_;

	foreach my $guildmember (@{$guild{member}}) {
		if ($guildmember->{charID} eq $args->{charID}) {
			if ($guildmember->{online} = $args->{online}) {
				message TF("Guild member %s logged in.\n", $guildmember->{name}), "guildchat";
			} else {
				message TF("Guild member %s logged out.\n", $guildmember->{name}), "guildchat";
			}
			last;
		}
	}
}

sub guild_members_title_list {
	my ($self, $args) = @_;
	
	my $newmsg;
	my $msg = $args->{RAW_MSG};
	my $msg_size = $args->{RAW_MSG_SIZE};
	
	$self->decrypt(\$newmsg, substr($msg, 4, length($msg) - 4));
	$msg = substr($msg, 0, 4) . $newmsg;
	my $gtIndex;
	for (my $i = 4; $i < $msg_size; $i+=28) {
		$gtIndex = unpack("V1", substr($msg, $i, 4));
		$guild{positions}[$gtIndex]{title} = bytesToString(unpack("Z24", substr($msg, $i + 4, 24)));
	}
}

sub guild_name {
	my ($self, $args) = @_;
	
	my $guildID = $args->{guildID};
	my $emblemID = $args->{emblemID};
	my $mode = $args->{mode};
	my $guildName = bytesToString($args->{guildName});
	$char->{guild}{name} = $guildName;
	$char->{guildID} = $guildID;
	$char->{guild}{emblem} = $emblemID;
	
	$messageSender->sendGuildInfoRequest();	# Is this necessary?? (requests for guild info packet 014E)
	
	$messageSender->sendGuildRequest(0);	#requests for guild info packet 01B6 and 014C
	$messageSender->sendGuildRequest(1);	#requests for guild member packet 0166 and 0154
}

sub guild_notice {
	my ($self, $args) = @_;
	
	my $msg = $args->{RAW_MSG};
	my ($address) = unpack("Z*", substr($msg, 2, 60));
	my ($message) = unpack("Z*", substr($msg, 62, 120));
	stripLanguageCode(\$address);
	stripLanguageCode(\$message);
	$address = bytesToString($address);
	$message = bytesToString($message);

	# don't show the huge guildmessage notice if there is none
	# the client does something similar to this...
	if ($address || $message) {
		my $msg = TF("---Guild Notice---\n"	.
			"%s\n\n" .
			"%s\n" .
			"------------------\n", $address, $message);
		message $msg, "guildnotice";
	}

	#message	T("Requesting guild information...\n"), "info"; # Lets Disable this, its kinda useless.
	$messageSender->sendGuildInfoRequest();

	# Replies 01B6 (Guild Info) and 014C (Guild Ally/Enemy List)
	$messageSender->sendGuildRequest(0);

	# Replies 0166 (Guild Member Titles List) and 0154 (Guild Members List)
	$messageSender->sendGuildRequest(1);

}

sub guild_request {
	my ($self, $args) = @_;

	# Guild request
	my $ID = $args->{ID};
	my $name = bytesToString($args->{name});
	message TF("Incoming Request to join Guild '%s'\n", $name);
	$incomingGuild{'ID'} = $ID;
	$incomingGuild{'Type'} = 1;
	$timeout{'ai_guildAutoDeny'}{'time'} = time;	
}

sub identify {
	my ($self, $args) = @_;
	
	my $index = $args->{index};
	my $invIndex = findIndex($char->{inventory}, "index", $index);
	my $item = $char->{inventory}[$invIndex];
	$item->{identified} = 1;
	$item->{type_equip} = $itemSlots_lut{$item->{nameID}};
	message TF("Item Identified: %s (%d)\n", $item->{name}, $invIndex), "info";
	undef @identifyID;
}

sub identify_list {
	my ($self, $args) = @_;
	
	my $newmsg;
	my $msg = $args->{RAW_MSG};
	my $msg_size = $args->{RAW_MSG_SIZE};
	$self->decrypt(\$newmsg, substr($msg, 4));
	$msg = substr($msg, 0, 4).$newmsg;
	
	undef @identifyID;
	for (my $i = 4; $i < $msg_size; $i += 2) {
		my $index = unpack("v1", substr($msg, $i, 2));
		my $invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
		binAdd(\@identifyID, $invIndex);
	}
	
	my $num = @identifyID;
	message TF("Received Possible Identify List (%s item(s)) - type 'identify'\n", $num), 'info';
}

sub ignore_all_result {
	my ($self, $args) = @_;
	if ($args->{type} == 0) {
		message T("All Players ignored\n");
	} elsif ($args->{type} == 1) {
		if ($args->{error} == 0) {
			message T("All players unignored\n");
		}
	}
}

sub ignore_player_result {
	my ($self, $args) = @_;
	if ($args->{type} == 0) {
		message T("Player ignored\n");
	} elsif ($args->{type} == 1) {
		if ($args->{error} == 0) {
			message T("Player unignored\n");
		}
	}
}

sub inventory_item_added {
	my ($self, $args) = @_;

	changeToInGameState();

	my ($index, $amount, $fail) = ($args->{index}, $args->{amount}, $args->{fail});

	if (!$fail) {
		my $item;
		my $invIndex = findIndex($char->{inventory}, "index", $index);
		if (!defined $invIndex) {
			# Add new item
			$invIndex = findIndex($char->{inventory}, "nameID", "");
			$item = $char->{inventory}[$invIndex] = new Actor::Item();
			$item->{index} = $index;
			$item->{nameID} = $args->{nameID};
			$item->{type} = $args->{type};
			$item->{type_equip} = $args->{type_equip};
			$item->{amount} = $amount;
			$item->{identified} = $args->{identified};
			$item->{broken} = $args->{broken};
			$item->{upgrade} = $args->{upgrade};
			$item->{cards} = $args->{cards};
			$item->{name} = itemName($item);
		} else {
			# Add stackable item
			$item = $char->{inventory}[$invIndex];
			$item->{amount} += $amount;
		}
		$item->{invIndex} = $invIndex;

		$itemChange{$item->{name}} += $amount;
		my $disp = TF("Item added to inventory: %s (%d) x %d - %s", 
			$item->{name}, $invIndex, $amount, $itemTypes_lut{$item->{type}});
		message "$disp\n", "drop";

		$disp .= " ($field{name})\n";
		itemLog($disp);

		$args->{item} = $item;

		# TODO: move this stuff to AI()
		if ($ai_v{npc_talk}{itemID} eq $item->{nameID}) {
			$ai_v{'npc_talk'}{'talk'} = 'buy';
			$ai_v{'npc_talk'}{'time'} = time;
		}

		if ($AI == 2) {
			# Auto-drop item
			$item = $char->{inventory}[$invIndex];
			if (pickupitems(lc($item->{name})) == -1 && !AI::inQueue('storageAuto', 'buyAuto')) {
				$messageSender->sendDrop($item->{index}, $amount);
				message TF("Auto-dropping item: %s (%d) x %d\n", $item->{name}, $invIndex, $amount), "drop";
			}
		}

	} elsif ($fail == 6) {
		message T("Can't loot item...wait...\n"), "drop";
	} elsif ($fail == 2) {
		message T("Cannot pickup item (inventory full)\n"), "drop";
	} elsif ($fail == 1) {
		message T("Cannot pickup item (you're Frozen?)\n"), "drop";
	} else {
		message TF("Cannot pickup item (failure code %s)\n", $fail), "drop";
	}
}

sub inventory_item_removed {
	my ($self, $args) = @_;
	changeToInGameState();
	my $invIndex = findIndex($char->{inventory}, "index", $args->{index});
	$args->{item} = $char->{inventory}[$invIndex];
	inventoryItemRemoved($invIndex, $args->{amount});
	Plugins::callHook('packet_item_removed', {index => $invIndex});
}

sub item_used {
	my ($self, $args) = @_;

	my ($index, $itemID, $ID, $remaining) =
		@{$args}{qw(index itemID ID remaining)};

	if ($ID eq $accountID) {
		my $invIndex = findIndex($char->{inventory}, "index", $index);
		my $item = $char->{inventory}[$invIndex];
		my $amount = $item->{amount} - $remaining;
		$item->{amount} -= $amount;

		message TF("You used Item: %s (%d) x %d - %d left\n", $item->{name}, $invIndex, $amount, $remaining), "useItem", 1;
		$itemChange{$item->{name}}--;
		if ($item->{amount} <= 0) {
			delete $char->{inventory}[$invIndex];
		}

		Plugins::callHook('packet_useitem', {
			item => $item,
			invIndex => $invIndex,
			name => $item->{name},
			amount => $amount
		});
		$args->{item} = $item;

	} else {
		my $actor = Actor::get($ID);
		my $itemDisplay = itemNameSimple($itemID);
		message TF("%s used Item: %s - %s left\n", $actor, $itemDisplay, $remaining), "useItem", 2;
	}
}

sub married {
	my ($self, $args) = @_;

	my $actor = Actor::get($args->{ID});
	message TF("%s got married!\n", $actor);
}

sub revolving_entity {
	my ($self, $args) = @_;
	
	# Monk Spirits or Gunslingers' coins
	my $sourceID = $args->{sourceID};
	my $entities = $args->{entity};
	my $entityType = "spirit";
	$entityType = "coin" if ($char->{'jobID'} == 24);

	if ($sourceID eq $accountID) {
		message TF("You have %s ".$entityType."(s) now\n", $entities), "parseMsg_statuslook", 1 if $entities != $char->{spirits};
		$char->{spirits} = $entities;
	} elsif (my $actor = Actor::get($sourceID)) {
		$actor->{spirits} = $entities;
		message TF("%s has %s ".$entityType."(s) now\n", $actor, $entities), "parseMsg_statuslook", 2 if $entities != $actor->{spirits};
	}
	
}

sub inventory_items_equiped {
	my ($self, $args) = @_;
	changeToInGameState();
	my $newmsg;
	$self->decrypt(\$newmsg, substr($args->{RAW_MSG}, 4));
	my $msg = substr($args->{RAW_MSG}, 0, 4) . $newmsg;
	my $invIndex;
	for (my $i = 4; $i < $args->{RAW_MSG_SIZE}; $i += 24) {
		my $index = unpack("v1", substr($msg, $i, 2));
		my $ID = unpack("v1", substr($msg, $i + 2, 2));
		$invIndex = findIndex($char->{inventory}, "index", $index);
		$invIndex = findIndex($char->{inventory}, "nameID", "") unless defined $invIndex;

		my $item = $char->{inventory}[$invIndex] = new Actor::Item();
		$item->{index} = $index;
		$item->{invIndex} = $invIndex;
		$item->{nameID} = $ID;
		$item->{amount} = 1;
		$item->{type} = unpack("C1", substr($msg, $i + 4, 1));
		$item->{identified} = unpack("C1", substr($msg, $i + 5, 1));
		$item->{type_equip} = unpack("v1", substr($msg, $i + 6, 2));
		$item->{equipped} = unpack("v1", substr($msg, $i + 8, 2));
		$item->{broken} = unpack("C1", substr($msg, $i + 10, 1));
		$item->{upgrade} = unpack("C1", substr($msg, $i + 11, 1));
		$item->{cards} = substr($msg, $i + 12, 8);
		$item->{name} = itemName($item);
		if ($item->{equipped}) {
			foreach (%equipSlot_rlut){
				if ($_ & $item->{equipped}){
					next if $_ == 10; #work around Arrow bug
					$char->{equipment}{$equipSlot_lut{$_}} = $item;
				}
			}
		}


		debug "Inventory: $item->{name} ($invIndex) x $item->{amount} - $itemTypes_lut{$item->{type}} - $equipTypes_lut{$item->{type_equip}}\n", "parseMsg";
		Plugins::callHook('packet_inventory', {index => $invIndex});
	}

	$ai_v{'inventory_time'} = time + 1;
	$ai_v{'cart_time'} = time + 1;
}

sub inventory_items_nonstackable {
	my ($self, $args) = @_;
	changeToInGameState();
	my $newmsg;
	$self->decrypt(\$newmsg, substr($args->{RAW_MSG}, 4));
	my $msg = substr($args->{RAW_MSG}, 0, 4) . $newmsg;
	my $invIndex;
	for (my $i = 4; $i < $args->{RAW_MSG_SIZE}; $i += 20) {
		my $index = unpack("v1", substr($msg, $i, 2));
		my $ID = unpack("v1", substr($msg, $i + 2, 2));
		$invIndex = findIndex($char->{inventory}, "index", $index);
		$invIndex = findIndex($char->{inventory}, "nameID", "") unless defined $invIndex;

		my $item = $char->{inventory}[$invIndex] = new Actor::Item();
		$item->{index} = $index;
		$item->{invIndex} = $invIndex;
		$item->{nameID} = $ID;
		$item->{amount} = 1;
		$item->{type} = unpack("C1", substr($msg, $i + 4, 1));
		$item->{identified} = unpack("C1", substr($msg, $i + 5, 1));
		$item->{type_equip} = unpack("v1", substr($msg, $i + 6, 2));
		$item->{equipped} = unpack("v1", substr($msg, $i + 8, 2));
		$item->{broken} = unpack("C1", substr($msg, $i + 10, 1));
		$item->{upgrade} = unpack("C1", substr($msg, $i + 11, 1));
		$item->{cards} = substr($msg, $i + 12, 8);
		$item->{name} = itemName($item);
		if ($item->{equipped}) {
			foreach (%equipSlot_rlut){
				if ($_ & $item->{equipped}){
					next if $_ == 10; #work around Arrow bug
					$char->{equipment}{$equipSlot_lut{$_}} = $item;
				}
			}
		}


		debug "Inventory: $item->{name} ($invIndex) x $item->{amount} - $itemTypes_lut{$item->{type}} - $equipTypes_lut{$item->{type_equip}}\n", "parseMsg";
		Plugins::callHook('packet_inventory', {index => $invIndex});
	}

	$ai_v{'inventory_time'} = time + 1;
	$ai_v{'cart_time'} = time + 1;
}

sub inventory_items_stackable {
	my ($self, $args) = @_;
	changeToInGameState();
	my $newmsg;
	$self->decrypt(\$newmsg, substr($msg, 4));
	my $msg = substr($args->{RAW_MSG}, 0, 4).$newmsg;
	my $psize = ($args->{switch} eq "00A3") ? 10 : 18;

	for (my $i = 4; $i < $args->{RAW_MSG_SIZE}; $i += $psize) {
		my $index = unpack("v1", substr($msg, $i, 2));
		my $ID = unpack("v1", substr($msg, $i + 2, 2));
		my $invIndex = findIndex($char->{inventory}, "index", $index);
		if ($invIndex eq "") {
			$invIndex = findIndex($char->{inventory}, "nameID", "");
		}

		my $item = $char->{inventory}[$invIndex] = new Actor::Item();
		$item->{invIndex} = $invIndex;
		$item->{index} = $index;
		$item->{nameID} = $ID;
		$item->{amount} = unpack("v1", substr($msg, $i + 6, 2));
		$item->{type} = unpack("C1", substr($msg, $i + 4, 1));
		$item->{identified} = 1;
		$item->{cards} = substr($msg, $i + 10, 8) if ($psize == 18);
		if (defined $char->{arrow} && $index == $char->{arrow}) {
			$item->{equipped} = 32768;
			$char->{equipment}{arrow} = $item;
		}
		$item->{name} = itemName($item);
		debug "Inventory: $item->{name} ($invIndex) x $item->{amount} - " .
			"$itemTypes_lut{$item->{type}}\n", "parseMsg";
		Plugins::callHook('packet_inventory', {index => $invIndex, item => $item});
	}

	$ai_v{'inventory_time'} = time + 1;
	$ai_v{'cart_time'} = time + 1;
}

sub item_appeared {
	my ($self, $args) = @_;
	changeToInGameState();

	my $item = $itemsList->getByID($args->{ID});
	my $mustAdd;
	if (!$item) {
		$item = new Actor::Item();
		$item->{appear_time} = time;
		$item->{amount} = $args->{amount};
		$item->{nameID} = $args->{type};
		$item->{name} = itemName($item);
		$item->{ID} = $args->{ID};
		$mustAdd = 1;
	}
	$item->{pos}{x} = $args->{x};
	$item->{pos}{y} = $args->{y};
	$item->{pos_to}{x} = $args->{x};
	$item->{pos_to}{y} = $args->{y};
	$itemsList->add($item) if ($mustAdd);

	# Take item as fast as possible

		# .mod itemsFastCollect {
		if ($AI && $config{'itemsFastCollect'} && (!binSize(\@playersID) || $config{'itemsIgnorePlayers'})
		&& ((pickupitems(lc($item->{name})) eq "1") || (pickupitems('all') && (pickupitems(lc($item->{name})) eq "")))
		&& distance($item->{pos}, $char->{pos_to}) <= 5) {
			$messageSender->sendTake($args->{ID});
		}
		# } .mod itemsFastCollect

	if ($AI == 2 && pickupitems(lc($item->{name})) == 2 && distance($item->{pos}, $char->{pos_to}) <= 5) {
		$messageSender->sendTake($args->{ID});
	}

	message TF("Item Appeared: %s (%d) x %d (%d, %d)\n", $item->{name}, $item->{binID}, $item->{amount}, $args->{x}, $args->{y}), "drop", 1;

}

sub item_exists {
	my ($self, $args) = @_;
	changeToInGameState();

	my $item = $itemsList->getByID($args->{ID});
	my $mustAdd;
	if (!$item) {
		$item = new Actor::Item();
		$item->{appear_time} = time;
		$item->{amount} = $args->{amount};
		$item->{nameID} = $args->{type};
		$item->{ID} = $args->{ID};
		$item->{name} = itemName($item);
		$mustAdd = 1;
	}
	$item->{pos}{x} = $args->{x};
	$item->{pos}{y} = $args->{y};
	$item->{pos_to}{x} = $args->{x};
	$item->{pos_to}{y} = $args->{y};
	$itemsList->add($item) if ($mustAdd);

	message TF("Item Exists: %s (%d) x %d\n", $item->{name}, $item->{binID}, $item->{amount}), "drop", 1;
}

sub item_disappeared {
	my ($self, $args) = @_;
	changeToInGameState();

	my $item = $itemsList->getByID($args->{ID});
	if ($item) {
		if ($config{attackLooters} && AI::action ne "sitAuto" && pickupitems(lc($item->{name})) > 0) {
			foreach my Actor::Monster $monster (@{$monstersList->getItems()}) { # attack looter code
				if (my $control = mon_control($monster->name,$monster->{nameID})) {
					next if ( ($control->{attack_auto}  ne "" && $control->{attack_auto} == -1)
						|| ($control->{attack_lvl}  ne "" && $control->{attack_lvl} > $char->{lv})
						|| ($control->{attack_jlvl} ne "" && $control->{attack_jlvl} > $char->{lv_job})
						|| ($control->{attack_hp}   ne "" && $control->{attack_hp} > $char->{hp})
						|| ($control->{attack_sp}   ne "" && $control->{attack_sp} > $char->{sp})
						);
				}
				if (distance($item->{pos}, $monster->{pos}) == 0) {
					attack($monster->{ID});
					message TF("Attack Looter: %s looted %s\n", $monster->nameIdx, $item->{name}), "looter";
					last;
				}
			}
		}

		debug "Item Disappeared: $item->{name} ($item->{binID})\n", "parseMsg_presence";
		my $ID = $args->{ID};
		$items_old{$ID} = $item->deepCopy();
		$items_old{$ID}{disappeared} = 1;
		$items_old{$ID}{gone_time} = time;
		$itemsList->removeByID($ID);
	}
}

sub item_skill {
	my ($self, $args) = @_;

	my $skillID = $args->{skillID};
	my $targetType = $args->{targetType}; # we don't use this yet
	my $skillLv = $args->{skillLv};
	my $sp = $args->{sp}; # we don't use this yet
	my $skillName = $args->{skillName};

	my $skill = new Skill(idn => $skillID);
	message TF("Permitted to use %s (%d), level %d\n", $skill->getName(), $skillID, $skillLv);

	unless ($config{noAutoSkill}) {
		$messageSender->sendSkillUse($skillID, $skillLv, $accountID);
		undef $char->{permitSkill};
	} else {
		$char->{permitSkill} = $skill;
	}

	Plugins::callHook('item_skill', {
		ID => $skillID,
		level => $skillLv,
		name => $skillName
	});	
}

sub item_upgrade {
	my ($self, $args) = @_;

	my ($type, $index, $upgrade) = @{$args}{qw(type index upgrade)};

	my $invIndex = findIndex($char->{inventory}, "index", $index);
	if (defined $invIndex) {
		my $item = $char->{inventory}[$invIndex];
		$item->{upgrade} = $upgrade;
		message TF("Item %s has been upgraded to +%s\n", $item->{name}, $upgrade), "parseMsg/upgrade";
		$item->{name} = itemName($item);
	}
}

sub job_equipment_hair_change {
	my ($self, $args) = @_;
	changeToInGameState();

	my $actor = Actor::get($args->{ID});
	assert(UNIVERSAL::isa($actor, "Actor")) if DEBUG;

	if ($args->{part} == 0) {
		# Job change
		$actor->{jobID} = $args->{number};
 		message TF("%s changed job to: %s\n", $actor, $jobs_lut{$args->{number}}), "parseMsg/job", ($actor->isa('Actor::You') ? 0 : 2);

	} elsif ($args->{part} == 3) {
		# Bottom headgear change
 		message TF("%s changed bottom headgear to: %s\n", $actor, headgearName($args->{number})), "parseMsg_statuslook", 2 unless $actor->isa('Actor::You');
		$actor->{headgear}{low} = $args->{number} if ($actor->isa('Actor::Player') || $actor->isa('Actor::You'));

	} elsif ($args->{part} == 4) {
		# Top headgear change
 		message TF("%s changed top headgear to: %s\n", $actor, headgearName($args->{number})), "parseMsg_statuslook", 2 unless $actor->isa('Actor::You');
		$actor->{headgear}{top} = $args->{number} if ($actor->isa('Actor::Player') || $actor->isa('Actor::You'));

	} elsif ($args->{part} == 5) {
		# Middle headgear change
 		message TF("%s changed middle headgear to: %s\n", $actor, headgearName($args->{number})), "parseMsg_statuslook", 2 unless $actor->isa('Actor::You');
		$actor->{headgear}{mid} = $args->{number} if ($actor->isa('Actor::Player') || $actor->isa('Actor::You'));

	} elsif ($args->{part} == 6) {
		# Hair color change
		$actor->{hair_color} = $args->{number};
 		message TF("%s changed hair color to: %s (%s)\n", $actor, $haircolors{$args->{number}}, $args->{number}), "parseMsg/hairColor", ($actor->isa('Actor::You') ? 0 : 2);
	}

	#my %parts = (
	#	0 => 'Body',
	#	2 => 'Right Hand',
	#	3 => 'Low Head',
	#	4 => 'Top Head',
	#	5 => 'Middle Head',
	#	8 => 'Left Hand'
	#);
	#if ($part == 3) {
	#	$part = 'low';
	#} elsif ($part == 4) {
	#	$part = 'top';
	#} elsif ($part == 5) {
	#	$part = 'mid';
	#}
	#
	#my $name = getActorName($ID);
	#if ($part == 3 || $part == 4 || $part == 5) {
	#	my $actor = Actor::get($ID);
	#	$actor->{headgear}{$part} = $items_lut{$number} if ($actor);
	#	my $itemName = $items_lut{$itemID};
	#	$itemName = 'nothing' if (!$itemName);
	#	debug "$name changes $parts{$part} ($part) equipment to $itemName\n", "parseMsg";
	#} else {
	#	debug "$name changes $parts{$part} ($part) equipment to item #$number\n", "parseMsg";
	#}

}

sub hp_sp_changed {
	my ($self, $args) = @_;
		
	my $type = $args->{type};
	my $amount = $args->{amount};
	if ($type == 5) {
		$chars[$config{'char'}]{'hp'} += $amount;
		$chars[$config{'char'}]{'hp'} = $chars[$config{'char'}]{'hp_max'} if ($chars[$config{'char'}]{'hp'} > $chars[$config{'char'}]{'hp_max'});
	} elsif ($type == 7) {
		$chars[$config{'char'}]{'sp'} += $amount;
		$chars[$config{'char'}]{'sp'} = $chars[$config{'char'}]{'sp_max'} if ($chars[$config{'char'}]{'sp'} > $chars[$config{'char'}]{'sp_max'});
	}	
}

sub local_broadcast {
	my ($self, $args) = @_;
	my $message = bytesToString($args->{message});
	message "$message\n", "schat";
}

sub login_error {
	my ($self, $args) = @_;

	$net->serverDisconnect();
	if ($args->{type} == 0) {
		error T("Account name doesn't exist\n"), "connection";
		if (!$net->clientAlive() && !$config{'ignoreInvalidLogin'} && !UNIVERSAL::isa($net, 'Network::XKoreProxy')) {
			my $username = $interface->query(T("Enter your Ragnarok Online username again."));
			if (defined($username)) {
				configModify('username', $username, 1);
				$timeout_ex{master}{time} = 0;
				$conState_tries = 0;
			} else {
				quit();
				return;
			}
		}
	} elsif ($args->{type} == 1) {
		error T("Password Error\n"), "connection";
		if (!$net->clientAlive() && !$config{'ignoreInvalidLogin'} && !UNIVERSAL::isa($net, 'Network::XKoreProxy')) {
			my $password = $interface->query(T("Enter your Ragnarok Online password again."), isPassword => 1);
			if (defined($password)) {
				configModify('password', $password, 1);
				$timeout_ex{master}{time} = 0;
				$conState_tries = 0;
			} else {
				quit();
				return;
			}
		}
	} elsif ($args->{type} == 3) {
		error T("Server connection has been denied\n"), "connection";
	} elsif ($args->{type} == 4) {
		$interface->errorDialog(T("Critical Error: Your account has been blocked."));
		$quit = 1 unless ($net->clientAlive());
	} elsif ($args->{type} == 5) {
		my $master = $masterServer;
		error TF("Connect failed, something is wrong with the login settings:\n" .
			"version: %s\n" .
			"master_version: %s\n" .
			"serverType: %s\n", $master->{version}, $master->{master_version}, $config{serverType}), "connection";
		relog(30);
	} elsif ($args->{type} == 6) {
		error T("The server is temporarily blocking your connection\n"), "connection";
	}
	if ($args->{type} != 5 && $versionSearch) {
		$versionSearch = 0;
		writeSectionedFileIntact("$Settings::tables_folder/servers.txt", \%masterServers);
	}
}

sub login_error_game_login_server {
	error T("Error logging into Character Server (invalid character specified)...\n"), 'connection';
	$net->setState(1);
	undef $conState_tries;
	$timeout_ex{master}{time} = time;
	$timeout_ex{master}{timeout} = $timeout{'reconnect'}{'timeout'};
	$net->serverDisconnect();
}

# The difference between map_change and map_changed is that map_change
# represents a map change event on the current map server, while
# map_changed means that you've changed to a different map server.
# map_change also represents teleport events.
sub map_change {
	my ($self, $args) = @_;
	changeToInGameState();

	my $oldMap = $field ? $field->name() : undef;
	my ($map) = $args->{map} =~ /([\s\S]*)\./;

	checkAllowedMap($map);
	if (!$field || $map ne $field->name()) {
		eval {
			$field = new Field(name => $map);
			# Temporary backwards compatibility code.
			%field = %{$field};
		};
		if (my $e = caught('FileNotFoundException', 'IOException')) {
			error TF("Cannot load field %s: %s\n", $map, $e);
			undef $field;
		} elsif ($@) {
			die $@;
		}
	}

	if ($ai_v{temp}{clear_aiQueue}) {
		AI::clear;
		AI::Homunculus::clear();
	}

	main::initMapChangeVars();
	for (my $i = 0; $i < @ai_seq; $i++) {
		ai_setMapChanged($i);
	}
	for (my $i = 0; $i < @AI::Homunculus::homun_ai_seq; $i++) {
		AI::Homunculus::homunculus_setMapChanged($i);
	}
	if ($net->version == 0) {
		$ai_v{portalTrace_mapChanged} = time;
	}

	my %coords = (
		x => $args->{x},
		y => $args->{y}
	);
	$chars[$config{char}]{pos} = {%coords};
	$chars[$config{char}]{pos_to} = {%coords};
	message TF("Map Change: %s (%s, %s)\n", $args->{map}, $chars[$config{'char'}]{'pos'}{'x'}, $chars[$config{'char'}]{'pos'}{'y'}), "connection";
	if ($net->version == 1) {
		ai_clientSuspend(0, 10);
	} else {
		$messageSender->sendMapLoaded();
		# Sending sync packet. Perhaps not only for server types 13 and 11
		if ($config{serverType} == 11 || $config{serverType} == 12 || $config{serverType} == 13 || $config{serverType} == 16) {
			$messageSender->sendSync(1);
		}
		$timeout{'ai'}{'time'} = time;
	}

	my %hookArgs = (oldMap => $oldMap);
	Plugins::callHook('Network::Receive::map_changed', \%hookArgs);
}

sub map_changed {
	my ($self, $args) = @_;
	$net->setState(4);

	my $oldMap = $field ? $field->name() : undef;
	my ($map) = $args->{map} =~ /([\s\S]*)\./;
	checkAllowedMap($map);
	if (!$field || $map ne $field->name()) {
		eval {
			$field = new Field(name => $map);
			# Temporary backwards compatibility code.
			%field = %{$field};
		};
		if (my $e = caught('FileNotFoundException', 'IOException')) {
			error TF("Cannot load field %s: %s\n", $map, $e);
			undef $field;
		} elsif ($@) {
			die $@;
		}
	}

	undef $conState_tries;
	for (my $i = 0; $i < @ai_seq; $i++) {
		ai_setMapChanged($i);
	}
	for (my $i = 0; $i < @AI::Homunculus::homun_ai_seq; $i++) {
		AI::Homunculus::homunculus_setMapChanged($i);
	}
	$ai_v{portalTrace_mapChanged} = time;

	$map_ip = makeIP($args->{IP});
	$map_port = $args->{port};
	message(swrite(
		"---------Map  Info----------", [],
		"MAP Name: @<<<<<<<<<<<<<<<<<<",
		[$args->{map}],
		"MAP IP: @<<<<<<<<<<<<<<<<<<",
		[$map_ip],
		"MAP Port: @<<<<<<<<<<<<<<<<<<",
		[$map_port],
		"-------------------------------", []),
		"connection");

	message T("Closing connection to Map Server\n"), "connection";
	$net->serverDisconnect unless ($net->version == 1);

	# Reset item and skill times. The effect of items (like aspd potions)
	# and skills (like Twohand Quicken) disappears when we change map server.
	# NOTE: with the newer servers, this isn't true anymore
	my $i = 0;
	while (exists $config{"useSelf_item_$i"}) {
		if (!$config{"useSelf_item_$i"}) {
			$i++;
			next;
		}

		$ai_v{"useSelf_item_$i"."_time"} = 0;
		$i++;
	}
	$i = 0;
	while (exists $config{"useSelf_skill_$i"}) {
		if (!$config{"useSelf_skill_$i"}) {
			$i++;
			next;
		}

		$ai_v{"useSelf_skill_$i"."_time"} = 0;
		$i++;
	}
	undef %{$chars[$config{char}]{statuses}} if ($chars[$config{char}]{statuses});
	$char->{spirits} = 0;
	undef $char->{permitSkill};
	undef $char->{encoreSkill};
	$cart{exists} = 0;
	undef %guild;

	my %hookArgs = (oldMap => $oldMap);
	Plugins::callHook('Network::Receive::map_changed', \%hookArgs);
}

sub map_loaded {
	#Note: ServerType0 overrides this function
	my ($self, $args) = @_;
	$net->setState(Network::IN_GAME);
	undef $conState_tries;
	$char = $chars[$config{'char'}];
	$syncMapSync = pack('V1',$args->{syncMapSync});

	if ($net->version == 1) {
		$net->setState(4);
		message T("Waiting for map to load...\n"), "connection";
		ai_clientSuspend(0, 10);
		main::initMapChangeVars();
	} else {
		#message	T("Requesting guild information...\n"), "info";
		$messageSender->sendGuildInfoRequest();

		# Replies 01B6 (Guild Info) and 014C (Guild Ally/Enemy List)
		$messageSender->sendGuildRequest(0);

		# Replies 0166 (Guild Member Titles List) and 0154 (Guild Members List)
		$messageSender->sendGuildRequest(1);
		message T("You are now in the game\n"), "connection";
		$messageSender->sendMapLoaded();
		$messageSender->sendSync(1);
		debug "Sent initial sync\n", "connection";
		$timeout{'ai'}{'time'} = time;
	}

	$char->{pos} = {};
	makeCoords($char->{pos}, $args->{coords});
	$char->{pos_to} = {%{$char->{pos}}};
	message TF("Your Coordinates: %s, %s\n", $char->{pos}{x}, $char->{pos}{y}), undef, 1;

	$messageSender->sendIgnoreAll("all") if ($config{'ignoreAll'});
}

sub memo_success {
	my ($self, $args) = @_;
	if ($args->{fail}) {
		warning T("Memo Failed\n");
	} else {
		message T("Memo Succeeded\n"), "success";
	}
}

sub minimap_indicator {
	my ($self, $args) = @_;
	
	if ($args->{clear}) {
		message TF("Minimap indicator at location %d, %d " .
		"with the color %s cleared\n", $args->{x}, $args->{y}, $args->{color}),
		"info";
	} else {
		message TF("Minimap indicator at location %d, %d " .
		"with the color %s shown\n", $args->{x}, $args->{y}, $args->{color}),
		"info";
	}
}

sub monster_typechange {
	my ($self, $args) = @_;
	
	# Class change / monster type change
	# 01B0 : long ID, byte WhateverThisIs, long type
	my $ID = $args->{ID};
	my $type = $args->{type};
	my $monster = $monstersList->getByID($ID);
	if ($monster) {
		my $oldName = $monster->name;
		if ($monsters_lut{$type}) {
			$monster->setName($monsters_lut{$type});
		} else {
			$monster->setName(undef);
		}
		$monster->{nameID} = $type;
		$monster->{dmgToParty} = 0;
		$monster->{dmgFromParty} = 0;
		$monster->{missedToParty} = 0;
		message TF("Monster %s (%d) changed to %s\n", $oldName, $monster->{binID}, $monster->name);
	}
}

sub monster_ranged_attack {
	my ($self, $args) = @_;
	
	my $ID = $args->{ID};
	my $type = $args->{type};
	
	my %coords1;
	$coords1{x} = $args->{sourceX};
	$coords1{y} = $args->{sourceY};
	my %coords2;
	$coords2{x} = $args->{targetX};
	$coords2{y} = $args->{targetY};

	my $monster = $monstersList->getByID($ID);
	$monster->{pos_attack_info} = {%coords1} if ($monster);
	$char->{pos} = {%coords2};
	$char->{pos_to} = {%coords2};
	debug "Received attack location - monster: $coords1{x},$coords1{y} - " .
		"you: $coords2{x},$coords2{y}\n", "parseMsg_move", 2;	
}

sub mvp_item {
	my ($self, $args) = @_;
	my $display = itemNameSimple($args->{itemID});
	message TF("Get MVP item %s\n", $display);
	chatLog("k", TF("Get MVP item %s\n", $display));
}

sub mvp_other {
	my ($self, $args) = @_;
	my $display = Actor::get($args->{ID});
	message TF("%s become MVP!\n", $display);
	chatLog("k", TF("%s became MVP!\n", $display));
}

sub mvp_you {
	my ($self, $args) = @_;
	my $msg = TF("Congratulations, you are the MVP! Your reward is %s exp!\n", $args->{expAmount});
	message $msg;
	chatLog("k", $msg);
}

sub npc_image {
	my ($self, $args) = @_;
	my ($imageName) = bytesToString($args->{npc_image});
	if ($args->{type} == 2) {
		debug "Show NPC image: $imageName\n", "parseMsg";
	} elsif ($args->{type} == 255) {
		debug "Hide NPC image: $imageName\n", "parseMsg";
	} else {
		debug "NPC image: $imageName ($args->{type})\n", "parseMsg";
	}
}

sub npc_sell_list {
	my ($self, $args) = @_;
	#sell list, similar to buy list
	if (length($args->{RAW_MSG}) > 4) {
		my $newmsg;
		$self->decrypt(\$newmsg, substr($args->{RAW_MSG}, 4));
		my $msg = substr($args->{RAW_MSG}, 0, 4).$newmsg;
	}
	undef $talk{buyOrSell};
	message T("Ready to start selling items\n");

	# continue talk sequence now
	$ai_v{npc_talk}{time} = time;
}

sub npc_store_begin {
	my ($self, $args) = @_;
	undef %talk;
	$talk{buyOrSell} = 1;
	$talk{ID} = $args->{ID};
	$ai_v{npc_talk}{talk} = 'buy';
	$ai_v{npc_talk}{time} = time;

	my $name = getNPCName($args->{ID});

	message TF("%s: Type 'store' to start buying, or type 'sell' to start selling\n", $name), "npc";
}

sub npc_store_info {
	my ($self, $args) = @_;
	my $newmsg;
	$self->decrypt(\$newmsg, substr($args->{RAW_MSG}, 4));
	my $msg = substr($args->{RAW_MSG}, 0, 4).$newmsg;
	undef @storeList;
	my $storeList = 0;
	undef $talk{'buyOrSell'};
	for (my $i = 4; $i < $args->{RAW_MSG_SIZE}; $i += 11) {
		my $price = unpack("V1", substr($msg, $i, 4));
		my $type = unpack("C1", substr($msg, $i + 8, 1));
		my $ID = unpack("v1", substr($msg, $i + 9, 2));

		my $store = $storeList[$storeList] = {};
		my $display = ($items_lut{$ID} ne "")
			? $items_lut{$ID}
			: "Unknown ".$ID;
		$store->{name} = $display;
		$store->{nameID} = $ID;
		$store->{type} = $type;
		$store->{price} = $price;
		debug "Item added to Store: $store->{name} - $price z\n", "parseMsg", 2;
		$storeList++;
	}

	my $name = getNPCName($talk{ID});
	$ai_v{npc_talk}{talk} = 'store';
	# continue talk sequence now
	$ai_v{'npc_talk'}{'time'} = time;

	if (AI::action ne 'buyAuto') {
		message TF("----------%s's Store List-----------\n" .
			"#  Name                    Type               Price\n", $name), "list";
		my $display;
		for (my $i = 0; $i < @storeList; $i++) {
			$display = $storeList[$i]{'name'};
			message(swrite(
				"@< @<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<<< @>>>>>>>z",
				[$i, $display, $itemTypes_lut{$storeList[$i]{'type'}}, $storeList[$i]{'price'}]),
				"list");
		}
		message("-------------------------------\n", "list");
	}
}

sub npc_talk {
	my ($self, $args) = @_;
	my $newmsg;
	$self->decrypt(\$newmsg, substr($args->{RAW_MSG}, 8));

	my $msg = substr($args->{RAW_MSG}, 0, 8) . $newmsg;
	my $ID = substr($msg, 4, 4);
	my $talkMsg = unpack("Z*", substr($msg, 8));
	$talk{ID} = $ID;
	$talk{nameID} = unpack("V1", $ID);
	$talk{msg} = bytesToString($talkMsg);
	# Remove RO color codes
	$talk{msg} =~ s/\^[a-fA-F0-9]{6}//g;

	$ai_v{npc_talk}{talk} = 'initiated';
	$ai_v{npc_talk}{time} = time;

	my $name = getNPCName($ID);
	message "$name: $talk{msg}\n", "npc";
}

sub npc_talk_close {
	my ($self, $args) = @_;
	# 00b6: long ID
	# "Close" icon appreared on the NPC message dialog
	my $ID = $args->{ID};
	my $name = getNPCName($ID);

	message TF("%s: Done talking\n", $name), "npc";

	# I noticed that the RO client doesn't send a 'talk cancel' packet
	# when it receives a 'npc_talk_closed' packet from the server'.
	# But on pRO Thor (with Kapra password) this is required in order to
	# open the storage.
	#
	# UPDATE: not sending 'talk cancel' breaks autostorage on iRO.
	# This needs more investigation.
	if (!$talk{canceled}) {
		$messageSender->sendTalkCancel($ID);
	}

	$ai_v{npc_talk}{talk} = 'close';
	$ai_v{npc_talk}{time} = time;
	undef %talk;

	Plugins::callHook('npc_talk_done', {ID => $ID});
}

sub npc_talk_continue {
	my ($self, $args) = @_;
	my $ID = substr($args->{RAW_MSG}, 2, 4);
	my $name = getNPCName($ID);

	$ai_v{npc_talk}{talk} = 'next';
	$ai_v{npc_talk}{time} = time;

	if ($config{autoTalkCont}) {
		message TF("%s: Auto-continuing talking\n", $name), "npc";
		$messageSender->sendTalkContinue($ID);
		# This time will be reset once the NPC responds
		$ai_v{npc_talk}{time} = time + $timeout{'ai_npcTalk'}{'timeout'} + 5;
	} else {
		message TF("%s: Type 'talk cont' to continue talking\n", $name), "npc";
	}
}

sub npc_talk_number {
	my ($self, $args) = @_;

	my $ID = $args->{ID};

	my $name = getNPCName($ID);
	$ai_v{npc_talk}{talk} = 'number';
	$ai_v{npc_talk}{time} = time;

	message TF("%s: Type 'talk num <number #>' to input a number.\n", $name), "input";
	$ai_v{'npc_talk'}{'talk'} = 'num';
	$ai_v{'npc_talk'}{'time'} = time;
}

sub npc_talk_responses {
	my ($self, $args) = @_;
	# 00b7: word len, long ID, string str
	# A list of selections appeared on the NPC message dialog.
	# Each item is divided with ':'
	my $newmsg;
	$self->decrypt(\$newmsg, substr($args->{RAW_MSG}, 8));
	my $msg = substr($msg, 0, 8).$newmsg;

	my $ID = substr($msg, 4, 4);
	$talk{ID} = $ID;
	my $talk = unpack("Z*", substr($msg, 8));
	$talk = substr($msg, 8) if (!defined $talk);
	$talk = bytesToString($talk);

	my @preTalkResponses = split /:/, $talk;
	$talk{responses} = [];
	foreach my $response (@preTalkResponses) {
		# Remove RO color codes
		$response =~ s/\^[a-fA-F0-9]{6}//g;
		if ($response =~ /^\^nItemID\^(\d+)$/) {
			$response = itemNameSimple($1);
		}

		push @{$talk{responses}}, $response if ($response ne "");
	}

	$talk{responses}[@{$talk{responses}}] = "Cancel Chat";

	$ai_v{'npc_talk'}{'talk'} = 'select';
	$ai_v{'npc_talk'}{'time'} = time;

	my $list = T("----------Responses-----------\n" .
		"#  Response\n");
	for (my $i = 0; $i < @{$talk{responses}}; $i++) {
		$list .= swrite(
			"@< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<",
			[$i, $talk{responses}[$i]]);
	}
	$list .= "-------------------------------\n";
	message($list, "list");

	my $name = getNPCName($ID);

	message TF("%s: Type 'talk resp #' to choose a response.\n", $name), "npc";
}

sub npc_talk_text {
	my ($self, $args) = @_;

	my $ID = $args->{ID};

	my $name = getNPCName($ID);
	message TF("%s: Type 'talk text' (Respond to NPC)\n", $name), "npc";
	$ai_v{npc_talk}{talk} = 'text';
	$ai_v{npc_talk}{time} = time;
}

sub party_chat {
	my ($self, $args) = @_;
	my $msg;

	$self->decrypt(\$msg, $args->{message});
	$msg = bytesToString($msg);

	# Type: String
	my ($chatMsgUser, $chatMsg) = $msg =~ /(.*?) : (.*)/;
	$chatMsgUser =~ s/ $//;

	stripLanguageCode(\$chatMsg);
	# Type: String
	my $chat = "$chatMsgUser : $chatMsg";
	message TF("[Party] %s\n", $chat), "partychat";

	chatLog("p", "$chat\n") if ($config{'logPartyChat'});
	ChatQueue::add('p', $args->{ID}, $chatMsgUser, $chatMsg);

	Plugins::callHook('packet_partyMsg', {
		MsgUser => $chatMsgUser,
		Msg => $chatMsg
	});
}

sub party_exp {
	my ($self, $args) = @_;
	$chars[$config{char}]{party}{share} = $args->{type};
	if ($args->{type} == 0) {
		message T("Party EXP set to Individual Take\n"), "party", 1;
	} elsif ($args->{type} == 1) {
		message T("Party EXP set to Even Share\n"), "party", 1;
	} else {
		error T("Error setting party option\n");
	}
}

sub party_hp_info {
	my ($self, $args) = @_;
	my $ID = $args->{ID};
	$chars[$config{char}]{party}{users}{$ID}{hp} = $args->{hp};
	$chars[$config{char}]{party}{users}{$ID}{hp_max} = $args->{hp_max};
}

sub party_invite {
	my ($self, $args) = @_;
	message TF("Incoming Request to join party '%s'\n", $args->{name});
	$incomingParty{ID} = $args->{ID};
	$timeout{ai_partyAutoDeny}{time} = time;
}

sub party_invite_result {
	my ($self, $args) = @_;
	if ($args->{type} == 0) {
		warning TF("Join request failed: %s is already in a party\n", $args->{name});
	} elsif ($args->{type} == 1) {
		warning TF("Join request failed: %s denied request\n", $args->{name});
	} elsif ($args->{type} == 2) {
		message TF("%s accepted your request\n", $args->{name}), "info";
	}
}

sub party_join {
	my ($self, $args) = @_;

	my ($ID, $x, $y, $type, $name, $user, $map) = @{$args}{qw(ID x y type name user map)};
	$name = bytesToString($name);
	$user = bytesToString($user);

	if (!$char->{party} || !%{$char->{party}} || !$chars[$config{char}]{party}{users}{$ID} || !%{$chars[$config{char}]{party}{users}{$ID}}) {
		binAdd(\@partyUsersID, $ID) if (binFind(\@partyUsersID, $ID) eq "");
		if ($ID eq $accountID) {
			message TF("You joined party '%s'\n", $name), undef, 1;
			$char->{party} = {};
		} else {
			message TF("%s joined your party '%s'\n", $user, $name), undef, 1;
		}
	}
	$chars[$config{char}]{party}{users}{$ID} = new Actor::Party;
	if ($type == 0) {
		$chars[$config{char}]{party}{users}{$ID}{online} = 1;
	} elsif ($type == 1) {
		$chars[$config{char}]{party}{users}{$ID}{online} = 0;
	}
	$chars[$config{char}]{party}{name} = $name;
	$chars[$config{char}]{party}{users}{$ID}{pos}{x} = $x;
	$chars[$config{char}]{party}{users}{$ID}{pos}{y} = $y;
	$chars[$config{char}]{party}{users}{$ID}{map} = $map;
	$chars[$config{char}]{party}{users}{$ID}{name} = $user;

	if ($config{partyAutoShare} && $char->{party} && $char->{party}{users}{$accountID}{admin}) {
		$messageSender->sendPartyShareEXP(1);
	}
}

sub party_leave {
	my ($self, $args) = @_;

	my $ID = $args->{ID};
	delete $chars[$config{char}]{party}{users}{$ID};
	binRemove(\@partyUsersID, $ID);
	if ($ID eq $accountID) {
		message T("You left the party\n");
		delete $chars[$config{char}]{party} if ($chars[$config{char}]{party});
		undef @partyUsersID;
	} else {
		message TF("%s left the party\n", bytesToString($args->{name}));
	}
}

sub party_location {
	my ($self, $args) = @_;
	
	my $ID = $args->{ID};
	$chars[$config{char}]{party}{users}{$ID}{pos}{x} = $args->{x};
	$chars[$config{char}]{party}{users}{$ID}{pos}{y} = $args->{y};
	$chars[$config{char}]{party}{users}{$ID}{online} = 1;
	debug "Party member location: $chars[$config{char}]{party}{users}{$ID}{name} - $args->{x}, $args->{y}\n", "parseMsg";
}

sub party_organize_result {
	my ($self, $args) = @_;
	if ($args->{fail}) {
		warning T("Can't organize party - party name exists\n");
	} else {
		$char->{party}{users}{$accountID}{admin} = 1;
	}
}

sub party_users_info {
	my ($self, $args) = @_;

	my $msg;
	$self->decrypt(\$msg, substr($args->{RAW_MSG}, 28));
	$msg = substr($args->{RAW_MSG}, 0, 28).$msg;
	$char->{party}{name} = bytesToString($args->{party_name});

	for (my $i = 28; $i < $args->{RAW_MSG_SIZE}; $i += 46) {
		my $ID = substr($msg, $i, 4);
		my $num = unpack("C1", substr($msg, $i + 44, 1));
		if (binFind(\@partyUsersID, $ID) eq "") {
			binAdd(\@partyUsersID, $ID);
		}
		$chars[$config{char}]{party}{users}{$ID} = new Actor::Party;
		$chars[$config{char}]{party}{users}{$ID}{name} = bytesToString(unpack("Z24", substr($msg, $i + 4, 24)));
		message TF("Party Member: %s\n", $chars[$config{char}]{party}{users}{$ID}{name}), undef, 1;
		$chars[$config{char}]{party}{users}{$ID}{map} = unpack("Z16", substr($msg, $i + 28, 16));
		$chars[$config{char}]{party}{users}{$ID}{online} = !(unpack("C1",substr($msg, $i + 45, 1)));
		$chars[$config{char}]{party}{users}{$ID}{admin} = 1 if ($num == 0);
	}

	$messageSender->sendPartyShareEXP(1) if ($config{partyAutoShare} && $chars[$config{char}]{party} && %{$chars[$config{char}]{party}});

}

sub pet_capture_result {
	my ($self, $args) = @_;

	if ($args->{success}) {
		message T("Pet capture success\n");
	} else {
		message T("Pet capture failed\n");
	}
}

sub pet_emotion {
	my ($self, $args) = @_;

	my ($ID, $type) = ($args->{ID}, $args->{type});

	my $emote = $emotions_lut{$type}{display} || "/e$type";
	if ($pets{$ID}) {
		message $pets{$ID}->name . " : $emote\n", "emotion";
	}
}

sub pet_food {
	my ($self, $args) = @_;
	if ($args->{success}) {
		message TF("Fed pet with %s\n", itemNameSimple($args->{foodID})), "pet";
	} else {
		error TF("Failed to feed pet with %s: no food in inventory.\n", itemNameSimple($args->{foodID}));
	}
}

sub pet_info {
	my ($self, $args) = @_;
	$pet{name} = bytesToString($args->{name});
	$pet{nameflag} = $args->{nameflag};
	$pet{level} = $args->{level};
	$pet{hungry} = $args->{hungry};
	$pet{friendly} = $args->{friendly};
	$pet{accessory} = $args->{accessory};
	debug "Pet status: name: $pet{name} name set?: ". ($pet{nameflag} ? 'yes' : 'no') ." level=$pet{level} hungry=$pet{hungry} intimacy=$pet{friendly} accessory=".itemNameSimple($pet{accessory})."\n", "pet";
}

sub pet_info2 {
	my ($self, $args) = @_;
	my ($type, $ID, $value) = @{$args}{qw(type ID value)};

	# receive information about your pet

	# related freya functions: clif_pet_equip clif_pet_performance clif_send_petdata

	# these should never happen, pets should spawn like normal actors (at least on Freya)
	# this isn't even very useful, do we want random pets with no location info?
	#if (!$pets{$ID} || !%{$pets{$ID}}) {
	#	binAdd(\@petsID, $ID);
	#	$pets{$ID} = {};
	#	%{$pets{$ID}} = %{$monsters{$ID}} if ($monsters{$ID} && %{$monsters{$ID}});
	#	$pets{$ID}{'name_given'} = "Unknown";
	#	$pets{$ID}{'binID'} = binFind(\@petsID, $ID);
	#	debug "Pet spawned (unusually): $pets{$ID}{'name'} ($pets{$ID}{'binID'})\n", "parseMsg";
	#}
	#if ($monsters{$ID}) {
	#	if (%{$monsters{$ID}}) {
	#		objectRemoved('monster', $ID, $monsters{$ID});
	#	}
	#	# always clear these in case
	#	binRemove(\@monstersID, $ID);
	#	delete $monsters{$ID};
	#}

	if ($type == 0) {
		# You own no pet.
		undef $pet{ID};

	} elsif ($type == 1) {
		$pet{friendly} = $value;
		debug "Pet friendly: $value\n";

	} elsif ($type == 2) {
		$pet{hungry} = $value;
		debug "Pet hungry: $value\n";

	} elsif ($type == 3) {
		# accessory info for any pet in range
		#debug "Pet accessory info: $value\n";

	} elsif ($type == 4) {
		# performance info for any pet in range
		#debug "Pet performance info: $value\n";

	} elsif ($type == 5) {
		# You own pet with this ID
		$pet{ID} = $ID;
	}
}

sub player_equipment {
	my ($self, $args) = @_;

	my ($sourceID, $type, $ID1, $ID2) = @{$args}{qw(sourceID type ID1 ID2)};
	my $player = ($sourceID ne $accountID)? $playersList->getByID($sourceID) : $char;
	return unless $player;

	if ($type == 0) {
		# Player changed job
		$player->{jobID} = $ID1;
		
	} elsif ($type == 2) {
		if ($ID1 ne $player->{weapon}) {
			message TF("%s changed Weapon to %s\n", $player, itemName({nameID => $ID1})), "parseMsg_statuslook", 2;
			$player->{weapon} = $ID1;
		}
		if ($ID2 ne $player->{shield}) {
			message TF("%s changed Shield to %s\n", $player, itemName({nameID => $ID2})), "parseMsg_statuslook", 2;
			$player->{shield} = $ID2;
		}
	} elsif ($type == 3) {
		$player->{headgear}{low} = $ID1;
	} elsif ($type == 4) {
		$player->{headgear}{top} = $ID1;
	} elsif ($type == 5) {
		$player->{headgear}{mid} = $ID1;
	} elsif ($type == 9) {
		if ($player->{shoes} && $ID1 ne $player->{shoes}) {
			message TF("%s changed Shoes to: %s\n", $player, itemName({nameID => $ID1})), "parseMsg_statuslook", 2;
		}
		$player->{shoes} = $ID1;
	}
}

sub public_chat {
	my ($self, $args) = @_;
	# Type: String
	my $message = bytesToString($args->{message});
	my ($chatMsgUser, $chatMsg); # Type: String
	my ($actor, $dist);

	if ($message =~ /:/) {
		($chatMsgUser, $chatMsg) = split /:/, $message, 2;
		$chatMsgUser =~ s/ $//;
		$chatMsg =~ s/^ //;
		stripLanguageCode(\$chatMsg);

		$actor = Actor::get($args->{ID});
		$dist = "unknown";
		if (!$actor->isa('Actor::Unknown')) {
			$dist = distance($char->{pos_to}, $actor->{pos_to});
			$dist = sprintf("%.1f", $dist) if ($dist =~ /\./);
		}
		$message = "$chatMsgUser ($actor->{binID}): $chatMsg";

	} else {
		$chatMsg = $message;
	}

	my $position = sprintf("[%s %d, %d]",
		$field ? $field->name() : T("Unknown field,"),
		$char->{pos_to}{x}, $char->{pos_to}{y});
	my $distInfo;
	if ($actor) {
		$position .= sprintf(" [%d, %d] [dist=%s] (%d)",
			$actor->{pos_to}{x}, $actor->{pos_to}{y},
			$dist, $actor->{nameID});
		$distInfo = "[dist=$dist] ";
	}

	# this code autovivifies $actor->{pos_to} but it doesnt matter
	chatLog("c", "$position $message\n") if ($config{logChat});
	message TF("%s%s\n", $distInfo, $message), "publicchat";

	ChatQueue::add('c', $args->{ID}, $chatMsgUser, $chatMsg);
	Plugins::callHook('packet_pubMsg', {
		pubID => $args->{ID},
		pubMsgUser => $chatMsgUser,
		pubMsg => $chatMsg,
		MsgUser => $chatMsgUser,
		Msg => $chatMsg
	});
}

sub private_message {
	my ($self, $args) = @_;
	my ($newmsg, $msg); # Type: Bytes

	# Private message
	changeToInGameState();

	# Type: String
	my $privMsgUser = bytesToString($args->{privMsgUser});
	my $privMsg = bytesToString($args->{privMsg});

	if ($privMsgUser ne "" && binFind(\@privMsgUsers, $privMsgUser) eq "") {
		push @privMsgUsers, $privMsgUser;
		Plugins::callHook('parseMsg/addPrivMsgUser', {
			user => $privMsgUser,
			msg => $privMsg,
			userList => \@privMsgUsers
		});
	}

	stripLanguageCode(\$privMsg);
	chatLog("pm", TF("(From: %s) : %s\n", $privMsgUser, $privMsg)) if ($config{'logPrivateChat'});
 	message TF("(From: %s) : %s\n", $privMsgUser, $privMsg), "pm";

	ChatQueue::add('pm', undef, $privMsgUser, $privMsg);
	Plugins::callHook('packet_privMsg', {
		privMsgUser => $privMsgUser,
		privMsg => $privMsg,
		MsgUser => $privMsgUser,
		Msg => $privMsg
	});

	if ($config{dcOnPM} && $AI == 2) {
		chatLog("k", T("*** You were PM'd, auto disconnect! ***\n"));
		message T("Disconnecting on PM!\n");
		quit();
	}
}

sub private_message_sent {
	my ($self, $args) = @_;
	if ($args->{type} == 0) {
 		message TF("(To %s) : %s\n", $lastpm[0]{'user'}, $lastpm[0]{'msg'}), "pm/sent";
		chatLog("pm", "(To: $lastpm[0]{user}) : $lastpm[0]{msg}\n") if ($config{'logPrivateChat'});

		Plugins::callHook('packet_sentPM', {
			to => $lastpm[0]{user},
			msg => $lastpm[0]{msg}
		});

	} elsif ($args->{type} == 1) {
		warning TF("%s is not online\n", $lastpm[0]{user});
	} elsif ($args->{type} == 2) {
		warning T("Player ignored your message\n");
	} else {
		warning T("Player doesn't want to receive messages\n");
	}
	shift @lastpm;
}

# The block size in the received_characters packet varies from server to server.
# This method may be overrided in other ServerType handlers to return
# the correct block size.
sub received_characters_blockSize {
	if ($masterServer && $masterServer->{charBlockSize}) {
		return $masterServer->{charBlockSize};
	} else {
		return 106;
	}
}

sub received_characters {
	return if ($net->getState() == Network::IN_GAME);
	my ($self, $args) = @_;
	message T("Received characters from Character Server\n"), "connection";
	$net->setState(3);
	undef $conState_tries;
	undef @chars;

	Plugins::callHook('parseMsg/recvChars', $args->{options});
	if ($args->{options} && exists $args->{options}{charServer}) {
		$charServer = $args->{options}{charServer};
	} else {
		$charServer = $net->serverPeerHost . ":" . $net->serverPeerPort;
	}

	my $num;
	my $blockSize = $self->received_characters_blockSize();
	for (my $i = $args->{RAW_MSG_SIZE} % $blockSize; $i < $args->{RAW_MSG_SIZE}; $i += $blockSize) {
		#exp display bugfix - chobit andy 20030129
		$num = unpack("C1", substr($args->{RAW_MSG}, $i + 104, 1));
		$chars[$num] = new Actor::You;
		$chars[$num]{ID} = $accountID;
		$chars[$num]{charID} = substr($args->{RAW_MSG}, $i, 4);
		$chars[$num]{nameID} = unpack("V", $chars[$num]{ID});
		$chars[$num]{exp} = unpack("V", substr($args->{RAW_MSG}, $i + 4, 4));
		$chars[$num]{zenny} = unpack("V", substr($args->{RAW_MSG}, $i + 8, 4));
		$chars[$num]{exp_job} = unpack("V", substr($args->{RAW_MSG}, $i + 12, 4));
		$chars[$num]{lv_job} = unpack("v", substr($args->{RAW_MSG}, $i + 16, 2));
		$chars[$num]{hp} = unpack("v", substr($args->{RAW_MSG}, $i + 42, 2));
		$chars[$num]{hp_max} = unpack("v", substr($args->{RAW_MSG}, $i + 44, 2));
		$chars[$num]{sp} = unpack("v", substr($args->{RAW_MSG}, $i + 46, 2));
		$chars[$num]{sp_max} = unpack("v", substr($args->{RAW_MSG}, $i + 48, 2));
		$chars[$num]{jobID} = unpack("v", substr($args->{RAW_MSG}, $i + 52, 2));
		$chars[$num]{hair_style} = unpack("v", substr($args->{RAW_MSG}, $i + 54, 2));
		$chars[$num]{lv} = unpack("v", substr($args->{RAW_MSG}, $i + 58, 2));
		$chars[$num]{headgear}{low} = unpack("v", substr($args->{RAW_MSG}, $i + 62, 2));
		$chars[$num]{headgear}{top} = unpack("v", substr($args->{RAW_MSG}, $i + 66, 2));
		$chars[$num]{headgear}{mid} = unpack("v", substr($args->{RAW_MSG}, $i + 68, 2));
		$chars[$num]{hair_color} = unpack("v", substr($args->{RAW_MSG}, $i + 70, 2));
		$chars[$num]{clothes_color} = unpack("v", substr($args->{RAW_MSG}, $i + 72, 2));
		($chars[$num]{name}) = unpack("Z*", substr($args->{RAW_MSG}, $i + 74, 24));
		$chars[$num]{str} = unpack("C1", substr($args->{RAW_MSG}, $i + 98, 1));
		$chars[$num]{agi} = unpack("C1", substr($args->{RAW_MSG}, $i + 99, 1));
		$chars[$num]{vit} = unpack("C1", substr($args->{RAW_MSG}, $i + 100, 1));
		$chars[$num]{int} = unpack("C1", substr($args->{RAW_MSG}, $i + 101, 1));
		$chars[$num]{dex} = unpack("C1", substr($args->{RAW_MSG}, $i + 102, 1));
		$chars[$num]{luk} = unpack("C1", substr($args->{RAW_MSG}, $i + 103, 1));
		$chars[$num]{sex} = $accountSex2;
		$chars[$num]{name} = bytesToString($chars[$num]{name});
	}

	# gradeA says it's supposed to send this packet here, but
	# it doesn't work...
	# 30 Dec 2005: it didn't work before because it wasn't sending the accountiD -> fixed (kaliwanagan)
	$messageSender->sendBanCheck($accountID) if (!$net->clientAlive && $config{serverType} == 2);
	if (charSelectScreen(1) == 1) {
		$firstLoginMap = 1;
		$startingZenny = $chars[$config{'char'}]{'zenny'} unless defined $startingZenny;
		$sentWelcomeMessage = 1;
	}
}

sub received_character_ID_and_Map {
	my ($self, $args) = @_;
	message T("Received character ID and Map IP from Character Server\n"), "connection";
	$net->setState(4);
	undef $conState_tries;
	$charID = $args->{charID};

	if ($net->version == 1) {
		undef $masterServer;
		$masterServer = $masterServers{$config{master}} if ($config{master} ne "");
	}

	my ($map) = $args->{mapName} =~ /([\s\S]*)\./;
	if (!$field || $map ne $field->name()) {
		eval {
			$field = new Field(name => $map);
			# Temporary backwards compatibility code.
			%field = %{$field};
		};
		if (my $e = caught('FileNotFoundException', 'IOException')) {
			error TF("Cannot load field %s: %s\n", $map, $e);
			undef $field;
		} elsif ($@) {
			die $@;
		}
	}

	$map_ip = makeIP($args->{mapIP});
	$map_ip = $masterServer->{ip} if ($masterServer && $masterServer->{private});
	$map_port = $args->{mapPort};
	message TF("----------Game Info----------\n" .
		"Char ID: %s (%s)\n" .
		"MAP Name: %s\n" .
		"MAP IP: %s\n" .
		"MAP Port: %s\n" .
		"-----------------------------\n", getHex($charID), unpack("V1", $charID),
		$args->{mapName}, $map_ip, $map_port), "connection";
	($map) = $args->{mapName} =~ /([\s\S]*)\./;
	checkAllowedMap($map);
	message(T("Closing connection to Character Server\n"), "connection") unless ($net->version == 1);
	$net->serverDisconnect();
	main::initStatVars();
}

sub received_sync {
    changeToInGameState();
    debug "Received Sync\n", 'parseMsg', 2;
    $timeout{'play'}{'time'} = time;
}

sub refine_result {
	my ($self, $args) = @_;
	if ($args->{fail} == 0) {
		message TF("You successfully refined a weapon (ID %s)!\n", $args->{nameID});
	} elsif ($args->{fail} == 1) {
		message TF("You failed to refine a weapon (ID %s)!\n", $args->{nameID});
	} elsif ($args->{fail} == 2) {
		message TF("You successfully made a potion (ID %s)!\n", $args->{nameID});
	} elsif ($args->{fail} == 3) {
		message TF("You failed to make a potion (ID %s)!\n", $args->{nameID});
	} else {
		message TF("You tried to refine a weapon (ID %s); result: unknown %s\n", $args->{nameID}, $args->{fail});
	}
}

sub repair_list {
	my ($self, $args) = @_;
	my $msg;
	$msg .= T("--------Repair List--------\n");
	for (my $i = 4; $i < $args->{RAW_MSG_SIZE}; $i += 13) {
		my $index = unpack("v1", substr($args->{RAW_MSG}, $i, 2));
		my $nameID = unpack("v1", substr($args->{RAW_MSG}, $i+2, 2));
		# what are these  two?
		my $status = unpack("V1", substr($args->{RAW_MSG}, $i+4, 4));
		my $status2 = unpack("V1", substr($args->{RAW_MSG}, $i+8, 4));
		my $listID = unpack("C1", substr($args->{RAW_MSG}, $i+12, 1));
		my $name = itemNameSimple($nameID);
		$msg .= "$index $name\n";
		$messageSender->sendRepairItem($index) if ($config{repairAuto} && $i == 4);
	}
	$msg .= "---------------------------\n";
	message $msg, "list";
}

sub repair_result {
	my ($self, $args) = @_;
	
	my $itemName = itemNameSimple($args->{nameID});
	if ($args->{flag}) {
		message TF("Repair of %s failed.\n", $itemName);
	} else {
		message TF("Successfully repaired %s.\n", $itemName);
	}
}

sub resurrection {
	my ($self, $args) = @_;
	
	my $targetID = $args->{targetID};
	my $player = $playersList->getByID($targetID);
	my $type = $args->{type};

	if ($targetID eq $accountID) {
		message T("You have been resurrected\n"), "info";
		undef $char->{'dead'};
		undef $char->{'dead_time'};
		$char->{'resurrected'} = 1;

	} else {
		if ($player) {
			undef $player->{'dead'};
			$player->{deltaHp} = 0;
		}
		message TF("%s has been resurrected\n", getActorName($targetID)), "info";		
	}	
}

sub sage_autospell {
	# Sage Autospell - list of spells availible sent from server
	if ($config{autoSpell}) {
		my $skill = new Skill(name => $config{autoSpell});
		$messageSender->sendAutoSpell($skill->getIDN());
	}	
}

sub secure_login_key {
	my ($self, $args) = @_;
	$secureLoginKey = $args->{secure_key};
}

sub self_chat {
	my ($self, $args) = @_;
	my ($message, $chatMsgUser, $chatMsg); # Type: String

	$message = bytesToString($args->{message});

	($chatMsgUser, $chatMsg) = $message =~ /([\s\S]*?) : ([\s\S]*)/;
	# Note: $chatMsgUser/Msg may be undefined. This is the case on
	# eAthena servers: it uses this packet for non-chat server messages.

	if (defined $chatMsgUser) {
		stripLanguageCode(\$chatMsg);
	} else {
		$message = $message;
	}

	chatLog("c", "$message\n") if ($config{'logChat'});
	message "$message\n", "selfchat";

	Plugins::callHook('packet_selfChat', {
		user => $chatMsgUser,
		msg => $chatMsg
	});
}

sub sync_request {
	my ($self, $args) = @_;

	# 0187 - long ID
	# I'm not sure what this is. In inRO this seems to have something
	# to do with logging into the game server, while on
	# oRO it has got something to do with the sync packet.
	if ($config{serverType} == 1) {
		my $ID = $args->{ID};
		if ($ID == $accountID) {
			$timeout{ai_sync}{time} = time;
			$messageSender->sendSync() unless ($net->clientAlive);
			debug "Sync packet requested\n", "connection";
		} else {
			warning T("Sync packet requested for wrong ID\n");
		}
	}
}

sub taekwon_rank {
	my ($self, $args) = @_;
     message T("TaeKwon Mission Rank : ".$args->{rank}."\n"), "info";
}


sub taekwon_mission_receive {
	my ($self, $args) = @_;
     message T("TaeKwon Mission : ".$args->{monName}."(".$args->{value}."\%)"."\n"), "info";
}

sub no_teleport {
	my ($self, $args) = @_;
	my $fail = $args->{fail};

	if ($fail == 0) {
		error T("Unavailable Area To Teleport\n");
		AI::clear(qw/teleport/);
	} elsif ($fail == 1) {
		error T("Unavailable Area To Memo\n");
	} else {
		error TF("Unavailable Area To Teleport (fail code %s)\n", $fail);
	}
}

sub pvp_mode1 {
	my ($self, $args) = @_;
	my $type = $args->{type};

	if ($type == 0) {
		$pvp = 0;
	} elsif ($type == 1) {
		message T("PvP Display Mode\n"), "map_event";
		$pvp = 1;
	} elsif ($type == 3) {
		message T("GvG Display Mode\n"), "map_event";
		$pvp = 2;
	}
}

sub pvp_mode2 {
	my ($self, $args) = @_;
	my $type = $args->{type};

	if ($type == 0) {
		$pvp = 0;
	} elsif ($type == 6) {
		message T("PvP Display Mode\n"), "map_event";
		$pvp = 1;
	} elsif ($type == 8) {
		message T("GvG Display Mode\n"), "map_event";
		$pvp = 2;
	}
}

sub pvp_rank {
	my ($self, $args) = @_;

	# 9A 01 - 14 bytes long
	my $ID = $args->{ID};
	my $rank = $args->{rank};
	my $num = $args->{num};;
	if ($rank != $ai_v{temp}{pvp_rank} ||
	    $num != $ai_v{temp}{pvp_num}) {
		$ai_v{temp}{pvp_rank} = $rank;
		$ai_v{temp}{pvp_num} = $num;
		if ($ai_v{temp}{pvp}) {
			message TF("Your PvP rank is: %s/%s\n", $rank, $num), "map_event";
		}
	}	
}

sub sense_result {
	my ($self, $args) = @_;
	# nameID level size hp def race mdef element ice earth fire wind poison holy dark spirit undead
	my @race_lut = qw(Formless Undead Beast Plant Insect Fish Demon Demi-Human Angel Dragon Boss Non-Boss);
	my @size_lut = qw(Small Medium Large);
	message TF("=====================Sense========================\n" .
			"Monster: %-16s Level: %-12s\n" .
			"Size:    %-16s Race:  %-12s\n" .
			"Def:     %-16s MDef:  %-12s\n" .
			"Element: %-16s HP:    %-12s\n" .
			"=================Damage Modifiers=================\n" .
			"Ice: %-3s     Earth: %-3s  Fire: %-3s  Wind: %-3s\n" .
			"Poison: %-3s  Holy: %-3s   Dark: %-3s  Spirit: %-3s\n" .
			"Undead: %-3s\n" .
			"==================================================\n",
			$monsters_lut{$args->{nameID}}, $args->{level}, $size_lut[$args->{size}], $race_lut[$args->{race}], 
			$args->{def}, $args->{mdef}, $elements_lut{$args->{element}}, $args->{hp},
			$args->{ice}, $args->{earth}, $args->{fire}, $args->{wind}, $args->{poison}, $args->{holy}, $args->{dark},
			$args->{spirit}, $args->{undead}), "list";
}

sub shop_sold {
	my ($self, $args) = @_;
	
	# sold something
	my $number = $args->{number};
	my $amount = $args->{amount};
	
	$articles[$number]{sold} += $amount;
	my $earned = $amount * $articles[$number]{price};
	$shopEarned += $earned;
	$articles[$number]{quantity} -= $amount;
	my $msg = TF("sold: %s - %s %sz\n", $amount, $articles[$number]{name}, $earned);
	shopLog($msg);
	message($msg, "sold");
	if ($articles[$number]{quantity} < 1) {
		message TF("sold out: %s\n", $articles[$number]{name}), "sold";
		#$articles[$number] = "";
		if (!--$articles){
			message T("Items have been sold out.\n"), "sold";
			closeShop();
		}
	}
}

sub shop_skill {
	my ($self, $args) = @_;

	# Used the shop skill.
	my $number = $args->{number};
	message TF("You can sell %s items!\n", $number);
}

sub skill_cast {
	my ($self, $args) = @_;

	changeToInGameState();
	my $sourceID = $args->{sourceID};
	my $targetID = $args->{targetID};
	my $x = $args->{x};
	my $y = $args->{y};
	my $skillID = $args->{skillID};
	my $type = $args->{type};
	my $wait = $args->{wait};
	my ($dist, %coords);

	# Resolve source and target
	my $source = Actor::get($sourceID);
	my $target = Actor::get($targetID);
	my $verb = $source->verb('are casting', 'is casting');

	Misc::checkValidity("skill_cast part 1");

	my $skill = new Skill(idn => $skillID);
	$source->{casting} = {
		skill => $skill,
		target => $target,
		x => $x,
		y => $y,
		startTime => time,
		castTime => $wait
	};
	# Since we may have a circular reference, weaken this reference
	# to prevent memory leaks.
	Scalar::Util::weaken($source->{casting}{target});

	my $targetString;
	if ($x != 0 || $y != 0) {
		# If $dist is positive we are in range of the attack?
		$coords{x} = $x;
		$coords{y} = $y;
		$dist = judgeSkillArea($skillID) - distance($char->{pos_to}, \%coords);
			$targetString = "location ($x, $y)";
		undef $targetID;
	} else {
		$targetString = $target->nameString($source);
	}

	# Perform trigger actions
	if ($sourceID eq $accountID) {
		$char->{time_cast} = time;
		$char->{time_cast_wait} = $wait / 1000;
		delete $char->{cast_cancelled};
	}
	countCastOn($sourceID, $targetID, $skillID, $x, $y);

	Misc::checkValidity("skill_cast part 2");

	my $domain = ($sourceID eq $accountID) ? "selfSkill" : "skill";
	my $disp = skillCast_string($source, $target, $x, $y, $skill->getName(), $wait);
	message $disp, $domain, 1;

	Plugins::callHook('is_casting', {
		sourceID => $sourceID,
		targetID => $targetID,
		source => $source,
		target => $target,
		skillID => $skillID,
		skill => $skill,
		time => $source->{casting}{time},
		castTime => $wait,
		x => $x,
		y => $y
	});

	Misc::checkValidity("skill_cast part 3");

	# Skill Cancel
	my $monster = $monstersList->getByID($sourceID);
	my $control;
	$control = mon_control($monster->name,$monster->{nameID}) if ($monster);
	if ($AI == 2 && $control->{skillcancel_auto}) {
		if ($targetID eq $accountID || $dist > 0 || (AI::action eq "attack" && AI::args->{ID} ne $sourceID)) {
			message TF("Monster Skill - switch Target to : %s (%d)\n", $monster->name, $monster->{binID});
			stopAttack();
			AI::dequeue;
			attack($sourceID);
		}

		# Skill area casting -> running to monster's back
		my $ID;
		if ($dist > 0 && AI::action eq "attack" && ($ID = AI::args->{ID}) && (my $monster2 = $monstersList->getByID($ID))) {
			# Calculate X axis
			if ($char->{pos_to}{x} - $monster2->{pos_to}{x} < 0) {
				$coords{x} = $monster2->{pos_to}{x} + 3;
			} else {
				$coords{x} = $monster2->{pos_to}{x} - 3;
			}
			# Calculate Y axis
			if ($char->{pos_to}{y} - $monster2->{pos_to}{y} < 0) {
				$coords{y} = $monster2->{pos_to}{y} + 3;
			} else {
				$coords{y} = $monster2->{pos_to}{y} - 3;
			}

			my (%vec, %pos);
			getVector(\%vec, \%coords, $char->{pos_to});
			moveAlongVector(\%pos, $char->{pos_to}, \%vec, distance($char->{pos_to}, \%coords));
			ai_route($field{name}, $pos{x}, $pos{y},
				maxRouteDistance => $config{attackMaxRouteDistance},
				maxRouteTime => $config{attackMaxRouteTime},
				noMapRoute => 1);
			message TF("Avoid casting Skill - switch position to : %s,%s\n", $pos{x}, $pos{y}), 1;
		}

		Misc::checkValidity("skill_cast part 4");
	}		
}

sub skill_update {
	my ($self, $args) = @_;

	my ($ID, $lv, $sp, $range, $up) = ($args->{skillID}, $args->{lv}, $args->{sp}, $args->{range}, $args->{up});

	my $skill = new Skill(idn => $ID);
	my $handle = $skill->getHandle();
	my $name = $skill->getName();
	$char->{skills}{$handle}{lv} = $lv;
	$char->{skills}{$handle}{sp} = $sp;
	$char->{skills}{$handle}{range} = $range;
	$char->{skills}{$handle}{up} = $up;

	Skill::DynamicInfo::add($ID, $handle, $lv, $sp, $range, $skill->getTargetType(), Skill::OWNER_CHAR);

	# Set $skillchanged to 2 so it knows to unset it when skill points are updated
	if ($skillChanged eq $handle) {
		$skillChanged = 2;
	}

	debug "Skill $name: $lv\n", "parseMsg";
}

sub skill_use {
	my ($self, $args) = @_;

	if (my $spell = $spells{$args->{sourceID}}) {
		# Resolve source of area attack skill
		$args->{sourceID} = $spell->{sourceID};
	}

	my $source = Actor::get($args->{sourceID});
	my $target = Actor::get($args->{targetID});
	$args->{source} = $source;
	$args->{target} = $target;
	delete $source->{casting};

	# Perform trigger actions
	changeToInGameState();
	updateDamageTables($args->{sourceID}, $args->{targetID}, $args->{damage}) if ($args->{damage} != -30000);
	setSkillUseTimer($args->{skillID}, $args->{targetID}) if ($args->{sourceID} eq $accountID);
	setPartySkillTimer($args->{skillID}, $args->{targetID}) if
		$args->{sourceID} eq $accountID or $args->{sourceID} eq $args->{targetID};
	countCastOn($args->{sourceID}, $args->{targetID}, $args->{skillID});

	# Resolve source and target names
	my $skill = new Skill(idn => $args->{skillID});
	$args->{skill} = $skill;
	my $disp = skillUse_string($source, $target, $skill->getName(), $args->{damage}, 
		$args->{level}, ($args->{src_speed}/10));

	if ($args->{damage} != -30000 &&
	    $args->{sourceID} eq $accountID &&
		$args->{targetID} ne $accountID) {
		calcStat($args->{damage});
	}

	my $domain = ($args->{sourceID} eq $accountID) ? "selfSkill" : "skill";

	if ($args->{damage} == 0) {
		$domain = "attackMonMiss" if (($args->{sourceID} eq $accountID && $args->{targetID} ne $accountID) || ($char->{homunculus} && $args->{sourceID} eq $char->{homunculus}{ID} && $args->{targetID} ne $char->{homunculus}{ID}));
		$domain = "attackedMiss" if (($args->{sourceID} ne $accountID && $args->{targetID} eq $accountID) || ($char->{homunculus} && $args->{sourceID} ne $char->{homunculus}{ID} && $args->{targetID} eq $char->{homunculus}{ID}));

	} elsif ($args->{damage} != -30000) {
		$domain = "attackMon" if (($args->{sourceID} eq $accountID && $args->{targetID} ne $accountID) || ($char->{homunculus} && $args->{sourceID} eq $char->{homunculus}{ID} && $args->{targetID} ne $char->{homunculus}{ID}));
		$domain = "attacked" if (($args->{sourceID} ne $accountID && $args->{targetID} eq $accountID) || ($char->{homunculus} && $args->{sourceID} ne $char->{homunculus}{ID} && $args->{targetID} eq $char->{homunculus}{ID}));
	}

	if ((($args->{sourceID} eq $accountID) && ($args->{targetID} ne $accountID)) ||
	    (($args->{sourceID} ne $accountID) && ($args->{targetID} eq $accountID))) {
		my $status = sprintf("[%3d/%3d] ", $char->hp_percent, $char->sp_percent);
		$disp = $status.$disp;
	} elsif ($char->{homunculus} && ((($args->{sourceID} eq $char->{homunculus}{ID}) && ($args->{targetID} ne $char->{homunculus}{ID})) ||
	    (($args->{sourceID} ne $char->{homunculus}{ID}) && ($args->{targetID} eq $char->{homunculus}{ID})))) {
		my $status = sprintf("[%3d/%3d] ", $char->{homunculus}{hpPercent}, $char->{homunculus}{spPercent});
		$disp = $status.$disp;
	}
	$target->{sitting} = 0 unless $args->{type} == 4 || $args->{type} == 9 || $args->{damage} == 0;

	Plugins::callHook('packet_skilluse', {
			'skillID' => $args->{skillID},
			'sourceID' => $args->{sourceID},
			'targetID' => $args->{targetID},
			'damage' => $args->{damage},
			'amount' => 0,
			'x' => 0,
			'y' => 0,
			'disp' => \$disp
		});

	message $disp, $domain, 1;

	if ($args->{targetID} eq $accountID && $args->{damage} > 0) {
		$damageTaken{$source->{name}}{$skill->getName()} += $args->{damage};
	}
}

sub skill_use_failed {
	my ($self, $args) = @_;

	# skill fail/delay
	my $skillID = $args->{skillID};
	my $btype = $args->{btype};
	my $fail = $args->{fail};
	my $type = $args->{type};

	my %failtype = (
		0 => 'Basic',
		1 => 'Insufficient SP',
		2 => 'Insufficient HP',
		3 => 'No Memo',
		4 => 'Mid-Delay',
		5 => 'No Zeny',
		6 => 'Wrong Weapon Type',
		7 => 'Red Gem Needed',
		8 => 'Blue Gem Needed',
		9 => '90% Overweight',
		10 => 'Requirement'
		);
	warning TF("Skill %s failed (%s)\n", Skill->new(idn => $skillID)->getName(), $failtype{$type}), "skill";
	Plugins::callHook('packet_skillfail', {
		skillID     => $skillID,
		failType    => $type,
		failMessage => $failtype{$type}
	});
}

sub skill_use_location {
	my ($self, $args) = @_;

	# Skill used on coordinates
	my $skillID = $args->{skillID};
	my $sourceID = $args->{sourceID};
	my $lv = $args->{lv};
	my $x = $args->{x};
	my $y = $args->{y};

	# Perform trigger actions
	setSkillUseTimer($skillID) if $sourceID eq $accountID;

	# Resolve source name
	my $source = Actor::get($sourceID);
	my $skillName = Skill->new(idn => $skillID)->getName();
	my $disp = skillUseLocation_string($source, $skillName, $args);

	# Print skill use message
	my $domain = ($sourceID eq $accountID) ? "selfSkill" : "skill";
	message $disp, $domain;

	Plugins::callHook('packet_skilluse', {
		'skillID' => $skillID,
		'sourceID' => $sourceID,
		'targetID' => '',
		'damage' => 0,
		'amount' => $lv,
		'x' => $x,
		'y' => $y
	});
}

sub skill_used_no_damage {
	my ($self, $args) = @_;
	# Skill used on target, with no damage done
	if (my $spell = $spells{$args->{sourceID}}) {
		# Resolve source of area attack skill
		$args->{sourceID} = $spell->{sourceID};
	}

	# Perform trigger actions
	changeToInGameState();
	setSkillUseTimer($args->{skillID}, $args->{targetID}) if ($args->{sourceID} eq $accountID
		&& $skillsArea{$args->{skillHandle}} != 2); # ignore these skills because they screw up monk comboing
	setPartySkillTimer($args->{skillID}, $args->{targetID}) if
			$args->{sourceID} eq $accountID or $args->{sourceID} eq $args->{targetID};
	countCastOn($args->{sourceID}, $args->{targetID}, $args->{skillID});
	if ($args->{sourceID} eq $accountID) {
		my $pos = calcPosition($char);
		$char->{pos_to} = $pos;
		$char->{time_move} = 0;
		$char->{time_move_calc} = 0;
	}

	# Resolve source and target names
	my $source = $args->{source} = Actor::get($args->{sourceID});
	my $target = $args->{target} = Actor::get($args->{targetID});
	my $verb = $source->verb('use', 'uses');

	delete $source->{casting};

	# Print skill use message
	my $extra = "";
	if ($args->{skillID} == 28) {
		$extra = ": $args->{amount} hp gained";
		updateDamageTables($args->{sourceID}, $args->{targetID}, -$args->{amount});
	} elsif ($args->{amount} != 65535) {
		$extra = ": Lv $args->{amount}";
	}

	my $domain = ($args->{sourceID} eq $accountID) ? "selfSkill" : "skill";
	my $skill = $args->{skill} = new Skill(idn => $args->{skillID});
	my $disp = skillUseNoDamage_string($source, $target, $skill->getIDN(), $skill->getName(), $args->{amount});
	message $disp, $domain;
	
	# Set teleport time
	if ($args->{sourceID} eq $accountID && $skill->getHandle() eq 'AL_TELEPORT') {
		$timeout{ai_teleport_delay}{time} = time;
	}

	if ($AI == 2 && $config{'autoResponseOnHeal'}) {
		# Handle auto-response on heal
		my $player = $playersList->getByID($args->{sourceID});
		if ($player && ($args->{skillID} == 28 || $args->{skillID} == 29 || $args->{skillID} == 34)) {
			if ($args->{targetID} eq $accountID) {
				chatLog("k", "***$source ".$skill->getName()." on $target$extra***\n");
				sendMessage("pm", getResponse("skillgoodM"), $player->name);
			} elsif ($monstersList->getByID($args->{targetID})) {
				chatLog("k", "***$source ".$skill->getName()." on $target$extra***\n");
				sendMessage("pm", getResponse("skillbadM"), $player->name);
			}
		}
	}
	Plugins::callHook('packet_skilluse', {
		skillID => $args->{skillID},
		sourceID => $args->{sourceID},
		targetID => $args->{targetID},
		damage => 0,
		amount => $args->{amount},
		x => 0,
		y => 0
	});
}

sub skills_list {
	my ($self, $args) = @_;

	# Character skill list
	changeToInGameState();
	my $newmsg;
	my $msg = $args->{RAW_MSG};
	my $msg_size = $args->{RAW_MSG_SIZE};
	
	$self->decrypt(\$newmsg, substr($msg, 4));
	$msg = substr($msg, 0, 4).$newmsg;

	undef @skillsID;
	delete $char->{skills};
	Skill::DynamicInfo::clear();
	for (my $i = 4; $i < $msg_size; $i += 37) {
		my $skillID = unpack("v1", substr($msg, $i, 2));
		# target type is 0 for novice skill, 1 for enemy, 2 for place, 4 for immediate invoke, 16 for party member
		my $targetType = unpack("v1", substr($msg, $i+2, 2)); # we don't use this yet
		my $level = unpack("v1", substr($msg, $i + 6, 2));
		my $sp = unpack("v1", substr($msg, $i + 8, 2));
		my $range = unpack("v1", substr($msg, $i + 10, 2));
		my ($handle) = unpack("Z*", substr($msg, $i + 12, 24));
		my $up = unpack("C1", substr($msg, $i+36, 1));
		if (!$handle) {
			$handle = Skill->new(idn => $skillID)->getHandle();
		}

		$char->{skills}{$handle}{ID} = $skillID;
		$char->{skills}{$handle}{sp} = $sp;
		$char->{skills}{$handle}{range} = $range;
		$char->{skills}{$handle}{up} = $up;
		$char->{skills}{$handle}{targetType} = $targetType;
		if (!$char->{skills}{$handle}{lv}) {
			$char->{skills}{$handle}{lv} = $level;
		}
		##
		# I have no idea what the importance of this line (original) is:
		#     $skillsID_lut{$skillID} = $skills_lut{$skillName};
		# translated to new Skill syntax:
		#     $Skills::skills{id}{$skillID}{name} = Skills->new(handle => lc($skillName))->name;
		# commented out
		binAdd(\@skillsID, $handle);

		Skill::DynamicInfo::add($skillID, $handle, $level, $sp, $range, $targetType, Skill::OWNER_CHAR);

		Plugins::callHook('packet_charSkills', {
			ID => $skillID,
			handle => $handle,
			level => $level,
		});
	}		
}

sub stats_added {
	my ($self, $args) = @_;
	
	if ($args->{val} == 207) {
		error T("Not enough stat points to add\n");
	} else {
		if ($args->{type} == 13) {
			$char->{str} = $args->{val};
			debug "Strength: $args->{val}\n", "parseMsg";
			# Reset $statChanged back to 0 to tell kore that a stat can be raised again
			$statChanged = 0 if ($statChanged eq "str");

		} elsif ($args->{type} == 14) {
			$char->{agi} = $args->{val};
			debug "Agility: $args->{val}\n", "parseMsg";
			$statChanged = 0 if ($statChanged eq "agi");

		} elsif ($args->{type} == 15) {
			$char->{vit} = $args->{val};
			debug "Vitality: $args->{val}\n", "parseMsg";
			$statChanged = 0 if ($statChanged eq "vit");

		} elsif ($args->{type} == 16) {
			$char->{int} = $args->{val};
			debug "Intelligence: $args->{val}\n", "parseMsg";
			$statChanged = 0 if ($statChanged eq "int");

		} elsif ($args->{type} == 17) {
			$char->{dex} = $args->{val};
			debug "Dexterity: $args->{val}\n", "parseMsg";
			$statChanged = 0 if ($statChanged eq "dex");

		} elsif ($args->{type} == 18) {
			$char->{luk} = $args->{val};
			debug "Luck: $args->{val}\n", "parseMsg";
			$statChanged = 0 if ($statChanged eq "luk");

		} else {
			debug "Something: $args->{val}\n", "parseMsg";
		}
	}
	Plugins::callHook('packet_charStats', {
		type	=> $args->{type},
		val	=> $args->{val},
	});
}

sub stats_info {
	my ($self, $args) = @_;
	$char->{points_free} = $args->{points_free};
	$char->{str} = $args->{str};
	$char->{points_str} = $args->{points_str};
	$char->{agi} = $args->{agi};
	$char->{points_agi} = $args->{points_agi};
	$char->{vit} = $args->{vit};
	$char->{points_vit} = $args->{points_vit};
	$char->{int} = $args->{int};
	$char->{points_int} = $args->{points_int};
	$char->{dex} = $args->{dex};
	$char->{points_dex} = $args->{points_dex};
	$char->{luk} = $args->{luk};
	$char->{points_luk} = $args->{points_luk};
	$char->{attack} = $args->{attack};
	$char->{attack_bonus} = $args->{attack_bonus};
	$char->{attack_magic_min} = $args->{attack_magic_min};
	$char->{attack_magic_max} = $args->{attack_magic_max};
	$char->{def} = $args->{def};
	$char->{def_bonus} = $args->{def_bonus};
	$char->{def_magic} = $args->{def_magic};
	$char->{def_magic_bonus} = $args->{def_magic_bonus};
	$char->{hit} = $args->{hit};
	$char->{flee} = $args->{flee};
	$char->{flee_bonus} = $args->{flee_bonus};
	$char->{critical} = $args->{critical};
	debug	"Strength: $char->{str} #$char->{points_str}\n"
		."Agility: $char->{agi} #$char->{points_agi}\n"
		."Vitality: $char->{vit} #$char->{points_vit}\n"
		."Intelligence: $char->{int} #$char->{points_int}\n"
		."Dexterity: $char->{dex} #$char->{points_dex}\n"
		."Luck: $char->{luk} #$char->{points_luk}\n"
		."Attack: $char->{attack}\n"
		."Attack Bonus: $char->{attack_bonus}\n"
		."Magic Attack Min: $char->{attack_magic_min}\n"
		."Magic Attack Max: $char->{attack_magic_max}\n"
		."Defense: $char->{def}\n"
		."Defense Bonus: $char->{def_bonus}\n"
		."Magic Defense: $char->{def_magic}\n"
		."Magic Defense Bonus: $char->{def_magic_bonus}\n"
		."Hit: $char->{hit}\n"
		."Flee: $char->{flee}\n"
		."Flee Bonus: $char->{flee_bonus}\n"
		."Critical: $char->{critical}\n"
		."Status Points: $char->{points_free}\n", "parseMsg";
}

sub stat_info {
	my ($self,$args) = @_;
	changeToInGameState();
	if ($args->{type} == 0) {
		$char->{walk_speed} = $args->{val} / 1000;
		debug "Walk speed: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 3) {
		debug "Something2: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 4) {
		if ($args->{val} == 0) {
			delete $char->{muted};
			delete $char->{mute_period};
			message T("Mute period expired.\n");
		} else {
			my $val = (0xFFFFFFFF - $args->{val}) + 1;
			$char->{mute_period} = $val * 60;
			$char->{muted} = time;
			if ($config{dcOnMute}) {
				message TF("You've been muted for %s minutes, auto disconnect!\n", $val);
				chatLog("k", TF("*** You have been muted for %s minutes, auto disconnect! ***\n", $val));
				quit();
			} else {
				message TF("You've been muted for %s minutes\n", $val);
			}
		}
	} elsif ($args->{type} == 5) {
		$char->{hp} = $args->{val};
		debug "Hp: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 6) {
		$char->{hp_max} = $args->{val};
		debug "Max Hp: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 7) {
		$char->{sp} = $args->{val};
		debug "Sp: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 8) {
		$char->{sp_max} = $args->{val};
		debug "Max Sp: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 9) {
		$char->{points_free} = $args->{val};
		debug "Status Points: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 11) {
		$char->{lv} = $args->{val};
		message TF("You are now level %s\n", $args->{val}), "success";
		if ($config{dcOnLevel} && $char->{lv} >= $config{dcOnLevel}) {
			message TF("Disconnecting on level %s!\n", $config{dcOnLevel});
			chatLog("k", TF("Disconnecting on level %s!\n", $config{dcOnLevel}));
			quit();
		}
	} elsif ($args->{type} == 12) {
		$char->{points_skill} = $args->{val};
		debug "Skill Points: $args->{val}\n", "parseMsg", 2;
		# Reset $skillChanged back to 0 to tell kore that a skill can be auto-raised again
		if ($skillChanged == 2) {
			$skillChanged = 0;
		}
	} elsif ($args->{type} == 24) {
		$char->{weight} = $args->{val} / 10;
		debug "Weight: $char->{weight}\n", "parseMsg", 2;
	} elsif ($args->{type} == 25) {
		$char->{weight_max} = int($args->{val} / 10);
		debug "Max Weight: $char->{weight_max}\n", "parseMsg", 2;
	} elsif ($args->{type} == 41) {
		$char->{attack} = $args->{val};
		debug "Attack: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 42) {
		$char->{attack_bonus} = $args->{val};
		debug "Attack Bonus: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 43) {
		$char->{attack_magic_max} = $args->{val};
		debug "Magic Attack Max: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 44) {
		$char->{attack_magic_min} = $args->{val};
		debug "Magic Attack Min: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 45) {
		$char->{def} = $args->{val};
		debug "Defense: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 46) {
		$char->{def_bonus} = $args->{val};
		debug "Defense Bonus: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 47) {
		$char->{def_magic} = $args->{val};
		debug "Magic Defense: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 48) {
		$char->{def_magic_bonus} = $args->{val};
		debug "Magic Defense Bonus: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 49) {
		$char->{hit} = $args->{val};
		debug "Hit: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 50) {
		$char->{flee} = $args->{val};
		debug "Flee: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 51) {
		$char->{flee_bonus} = $args->{val};
		debug "Flee Bonus: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 52) {
		$char->{critical} = $args->{val};
		debug "Critical: $args->{val}\n", "parseMsg", 2;
	} elsif ($args->{type} == 53) {
		$char->{attack_delay} = $args->{val};
		$char->{attack_speed} = 200 - $args->{val}/10;
		debug "Attack Speed: $char->{attack_speed}\n", "parseMsg", 2;
	} elsif ($args->{type} == 55) {
		$char->{lv_job} = $args->{val};
		message TF("You are now job level %s\n", $args->{val}), "success";
		if ($config{dcOnJobLevel} && $char->{lv_job} >= $config{dcOnJobLevel}) {
			message TF("Disconnecting on job level %s!\n", $config{dcOnJobLevel});
			chatLog("k", TF("Disconnecting on job level %s!\n", $config{dcOnJobLevel}));
			quit();
		}
	} elsif ($args->{type} == 124) {
		debug "Something3: $args->{val}\n", "parseMsg", 2;
	} else {
		debug "Something: $args->{val}\n", "parseMsg", 2;
	}
}

sub stat_info2 {
	my ($self, $args) = @_;
	my ($type, $val, $val2) = @{$args}{qw(type val val2)};
	if ($type == 13) {
		$char->{str} = $val;
		$char->{str_bonus} = $val2;
		debug "Strength: $val + $val2\n", "parseMsg";
	} elsif ($type == 14) {
		$char->{agi} = $val;
		$char->{agi_bonus} = $val2;
		debug "Agility: $val + $val2\n", "parseMsg";
	} elsif ($type == 15) {
		$char->{vit} = $val;
		$char->{vit_bonus} = $val2;
		debug "Vitality: $val + $val2\n", "parseMsg";
	} elsif ($type == 16) {
		$char->{int} = $val;
		$char->{int_bonus} = $val2;
		debug "Intelligence: $val + $val2\n", "parseMsg";
	} elsif ($type == 17) {
		$char->{dex} = $val;
		$char->{dex_bonus} = $val2;
		debug "Dexterity: $val + $val2\n", "parseMsg";
	} elsif ($type == 18) {
		$char->{luk} = $val;
		$char->{luk_bonus} = $val2;
		debug "Luck: $val + $val2\n", "parseMsg";
	}
}

sub stats_points_needed {
	my ($self, $args) = @_;
	if ($args->{type} == 32) {
		$char->{points_str} = $args->{val};
		debug "Points needed for Strength: $args->{val}\n", "parseMsg";
	} elsif ($args->{type}	== 33) {
		$char->{points_agi} = $args->{val};
		debug "Points needed for Agility: $args->{val}\n", "parseMsg";
	} elsif ($args->{type} == 34) {
		$char->{points_vit} = $args->{val};
		debug "Points needed for Vitality: $args->{val}\n", "parseMsg";
	} elsif ($args->{type} == 35) {
		$char->{points_int} = $args->{val};
		debug "Points needed for Intelligence: $args->{val}\n", "parseMsg";
	} elsif ($args->{type} == 36) {
		$char->{points_dex} = $args->{val};
		debug "Points needed for Dexterity: $args->{val}\n", "parseMsg";
	} elsif ($args->{type} == 37) {
		$char->{points_luk} = $args->{val};
		debug "Points needed for Luck: $args->{val}\n", "parseMsg";
	}
}

sub storage_closed {
	message T("Storage closed.\n"), "storage";
	delete $ai_v{temp}{storage_opened};
	Plugins::callHook('packet_storage_close');

	# Storage log
	writeStorageLog(0);
}

sub storage_item_added {
	my ($self, $args) = @_;

	my $index = $args->{index};
	my $amount = $args->{amount};

	my $item = $storage{$index} ||= {};
	if ($item->{amount}) {
		$item->{amount} += $amount;
	} else {
		binAdd(\@storageID, $index);
		$item->{nameID} = $args->{ID};
		$item->{index} = $index;
		$item->{amount} = $amount;
		$item->{type} = $args->{type};
		$item->{identified} = $args->{identified};
		$item->{broken} = $args->{broken};
		$item->{upgrade} = $args->{upgrade};
		$item->{cards} = $args->{cards};
		$item->{name} = itemName($item);
		$item->{binID} = binFind(\@storageID, $index);
	}
	message TF("Storage Item Added: %s (%d) x %s\n", $item->{name}, $item->{binID}, $amount), "storage", 1;
	$itemChange{$item->{name}} += $amount;
	$args->{item} = $item;
}

sub storage_item_removed {
	my ($self, $args) = @_;

	my ($index, $amount) = @{$args}{qw(index amount)};

	my $item = $storage{$index};
	$item->{amount} -= $amount;
	message TF("Storage Item Removed: %s (%d) x %s\n", $item->{name}, $item->{binID}, $amount), "storage";
	$itemChange{$item->{name}} -= $amount;
	$args->{item} = $item;
	if ($item->{amount} <= 0) {
		delete $storage{$index};
		binRemove(\@storageID, $index);
	}
}

sub storage_items_nonstackable {
	my ($self, $args) = @_;
	# Retrieve list of non-stackable (weapons & armor) storage items.
	# This packet is sent immediately after 00A5/01F0.
	my $newmsg;
	$self->decrypt(\$newmsg, substr($args->{RAW_MSG}, 4));
	my $msg = substr($args->{RAW_MSG}, 0, 4).$newmsg;

	for (my $i = 4; $i < $args->{RAW_MSG_SIZE}; $i += 20) {
		my $index = unpack("v1", substr($msg, $i, 2));
		my $ID = unpack("v1", substr($msg, $i + 2, 2));

		binAdd(\@storageID, $index);
		my $item = $storage{$index} = {};
		$item->{index} = $index;
		$item->{nameID} = $ID;
		$item->{amount} = 1;
		$item->{type} = unpack("C1", substr($msg, $i + 4, 1));
		$item->{identified} = unpack("C1", substr($msg, $i + 5, 1));
		$item->{broken} = unpack("C1", substr($msg, $i + 10, 1));
		$item->{upgrade} = unpack("C1", substr($msg, $i + 11, 1));
		$item->{cards} = substr($msg, $i + 12, 8);
		$item->{name} = itemName($item);
		$item->{binID} = binFind(\@storageID, $index);
		debug "Storage: $item->{name} ($item->{binID})\n", "parseMsg";
	}
}

sub storage_items_stackable {
	my ($self, $args) = @_;
	# Retrieve list of stackable storage items
	my $newmsg;
	$self->decrypt(\$newmsg, substr($args->{RAW_MSG}, 4));
	my $msg = substr($args->{RAW_MSG}, 0, 4).$newmsg;
	undef %storage;
	undef @storageID;

	my $psize = ($args->{switch} eq "00A5") ? 10 : 18;
	for (my $i = 4; $i < $args->{RAW_MSG_SIZE}; $i += $psize) {
		my $index = unpack("v1", substr($msg, $i, 2));
		my $ID = unpack("v1", substr($msg, $i + 2, 2));
		binAdd(\@storageID, $index);
		my $item = $storage{$index} = {};
		$item->{index} = $index;
		$item->{nameID} = $ID;
		$item->{type} = unpack("C1", substr($msg, $i + 4, 1));
		$item->{amount} = unpack("V1", substr($msg, $i + 6, 4)) & ~0x80000000;
		$item->{cards} = substr($msg, $i + 10, 8) if ($psize == 18);
		$item->{name} = itemName($item);
		$item->{binID} = binFind(\@storageID, $index);
		$item->{identified} = 1;
		debug "Storage: $item->{name} ($item->{binID}) x $item->{amount}\n", "parseMsg";
	}
}

sub storage_opened {
	my ($self, $args) = @_;
	$storage{items} = $args->{items};
	$storage{items_max} = $args->{items_max};

	$ai_v{temp}{storage_opened} = 1;
	if (!$storage{opened}) {
		$storage{opened} = 1;
		message T("Storage opened.\n"), "storage";
		Plugins::callHook('packet_storage_open');
	}
}

sub storage_password_request {
	my ($self, $args) = @_;

	if ($args->{flag} == 0) {
		message (($args->{switch} eq '023E') ?
			T("Please enter a new character password:\n") :
			T("Please enter a new storage password:\n"));

	} elsif ($args->{flag} == 1) {
		if ($args->{switch} eq '023E') {
			if ($config{charSelect_password} eq '') {
				my $input = $interface->query(T("Please enter your character password."), isPassword => 1);
				if (!defined($input)) {
					return;
				}
				configModify('charSelect_password', $input, 1);
				message TF("Character password set to: %s\n", $input), "success";
			}
		} else {
			if ($config{storageAuto_password} eq '') {
				my $input = $interface->query(T("Please enter your storage password."), isPassword => 1);
				if (!defined($input)) {
					return;
				}
				configModify('storageAuto_password', $input, 1);
				message TF("Storage password set to: %s\n", $input), "success";
			}
		}

		my @key = split /[, ]+/, $config{storageEncryptKey};
		if (!@key) {
			error (($args->{switch} eq '023E') ?
				T("Unable to send character password. You must set the 'storageEncryptKey' option in config.txt or servers.txt.\n") :
				T("Unable to send storage password. You must set the 'storageEncryptKey' option in config.txt or servers.txt.\n"));
			return;
		}
		my $crypton = new Utils::Crypton(pack("V*", @key), 32);
		my $num = ($args->{switch} eq '023E') ? $config{charSelect_password} : $config{storageAuto_password};
		$num = sprintf("%d%08d", length($num), $num);
		my $ciphertextBlock = $crypton->encrypt(pack("V*", $num, 0, 0, 0));
		$messageSender->sendStoragePassword($ciphertextBlock, 3);

	} elsif ($args->{flag} == 8) {	# apparently this flag means that you have entered the wrong password
									# too many times, and now the server is blocking you from using storage
		error T("You have entered the wrong password 5 times. Please try again later.\n");
		# temporarily disable storageAuto
		$config{storageAuto} = 0;
		my $index = AI::findAction('storageAuto');
		if (defined $index) {
			AI::args($index)->{done} = 1;
			while (AI::action ne 'storageAuto') {
				AI::dequeue;
			}
		}
	} else {
		debug(($args->{switch} eq '023E') ?
			"Character password: unknown flag $args->{flag}\n" :
			"Storage password: unknown flag $args->{flag}\n");
	}
}

sub storage_password_result {
	my ($self, $args) = @_;

	if ($args->{type} == 4) {
		message T("Successfully changed storage password.\n"), "success";
	} elsif ($args->{type} == 5) {
		error T("Error: Incorrect storage password.\n");
	} elsif ($args->{type} == 6) {
		message T("Successfully entered storage password.\n"), "success";
	} elsif ($args->{type} == 7) {
		error T("Error: Incorrect storage password.\n");
		# disable storageAuto or the Kafra storage will be blocked
		configModify("storageAuto", 0);
		my $index = AI::findAction('storageAuto');
		if (defined $index) {
			AI::args($index)->{done} = 1;
			while (AI::action ne 'storageAuto') {
				AI::dequeue;
			}
		}
	} else {
		#message "Storage password: unknown type $args->{type}\n";
	}

	# $args->{val}
	# unknown, what is this for?
}

sub switch_character {
	# 00B3 - user is switching characters in XKore
	$net->setState(2);
	$net->serverDisconnect();
}

sub system_chat {
	my ($self, $args) = @_;

	my $message = bytesToString($args->{message});
	stripLanguageCode(\$message);
	chatLog("s", "$message\n") if ($config{logSystemChat});
	# Translation Comment: System/GM chat
	message TF("[GM] %s\n", $message), "schat";
	ChatQueue::add('gm', undef, undef, $message);
	
	Plugins::callHook('packet_sysMsg', {
		Msg => $message
	});
}

sub top10_alchemist_rank {
	my ($self, $args) = @_;

	my $textList = top10Listing($args);
	message TF("============= ALCHEMIST RANK ================\n" .
		"#    Name                             Points\n".
		"%s" .
		"=============================================\n", $textList), "list";	
}

sub top10_blacksmith_rank {
	my ($self, $args) = @_;

	my $textList = top10Listing($args);
	message TF("============= BLACKSMITH RANK ===============\n" .
		"#    Name                             Points\n".
		"%s" .
		"=============================================\n", $textList), "list";
}

sub top10_pk_rank {
	my ($self, $args) = @_;

	my $textList = top10Listing($args);
	message TF("================ PVP RANK ===================\n" .
		"#    Name                             Points\n".
		"%s" .
		"=============================================\n", $textList), "list";
}

sub top10_taekwon_rank {
	my ($self, $args) = @_;

	my $textList = top10Listing($args);
	message TF("=============== TAEKWON RANK ================\n" .
		"#    Name                             Points\n".
		"%s" .
		"=============================================\n", $textList), "list";
}

sub unequip_item {
	my ($self, $args) = @_;

	changeToInGameState();
	my $invIndex = findIndex($char->{inventory}, "index", $args->{index});
	delete $char->{inventory}[$invIndex]{equipped} if ($char->{inventory}[$invIndex]);

	if ($args->{type} == 10) {
		delete $char->{equipment}{arrow};
	} else {
		foreach (%equipSlot_rlut){
			if ($_ & $args->{type}){
				next if $_ == 10; #work around Arrow bug
				delete $char->{equipment}{$equipSlot_lut{$_}};
			}
		}
	}

	my $item = $char->{inventory}[$invIndex];
	if ($item) {
		message TF("You unequip %s (%d) - %s\n", $item->{name}, $invIndex, $equipTypes_lut{$item->{type_equip}}), 'inventory';
	}
}

sub unit_levelup {
	my ($self, $args) = @_;
	
	my $ID = $args->{ID};
	my $type = $args->{type};
	my $name = getActorName($ID);
	if ($type == 0) {
		message TF("%s gained a level!\n", $name);
	} elsif ($type == 1) {
		message TF("%s gained a job level!\n", $name);
	} elsif ($type == 2) {
		message TF("%s failed to refine a weapon!\n", $name), "refine";
	} elsif ($type == 3) {
		message TF("%s successfully refined a weapon!\n", $name), "refine";
	}
}

sub use_item {
	my ($self, $args) = @_;
	
	changeToInGameState();
	my $invIndex = findIndex($char->{inventory}, "index", $args->{index});
	if (defined $invIndex) {
		$char->{inventory}[$invIndex]{amount} -= $args->{amount};
		message TF("You used Item: %s (%d) x %s\n", $char->{inventory}[$invIndex]{name}, $invIndex, $args->{amount}), "useItem";
		if ($char->{inventory}[$invIndex]{amount} <= 0) {
			delete $char->{inventory}[$invIndex];
		}
	}
}

sub users_online {
	my ($self, $args) = @_;
	
	message TF("There are currently %s users online\n", $args->{users}), "info";
}

sub vender_found {
	my ($self, $args) = @_;
	my $ID = $args->{ID};

	if (!$venderLists{$ID} || !%{$venderLists{$ID}}) {
		binAdd(\@venderListsID, $ID);
		Plugins::callHook('packet_vender', {ID => $ID});
	}
	$venderLists{$ID}{title} = bytesToString($args->{title});
	$venderLists{$ID}{id} = $ID;
}

sub vender_items_list {
	my ($self, $args) = @_;

	my $msg = $args->{RAW_MSG};
	my $msg_size = $args->{RAW_MSG_SIZE};
	
	undef @venderItemList;
	undef $venderID;
	$venderID = substr($msg,4,4);
	my $player = Actor::get($venderID);

	message TF("%s\n" .
		"#  Name                                       Type           Amount       Price\n", 
		center(' Vender: ' . $player->nameIdx . ' ', 79, '-')), "list";
	for (my $i = 8; $i < $msg_size; $i+=22) {
		my $number = unpack("v1", substr($msg, $i + 6, 2));

		my $item = $venderItemList[$number] = {};
		$item->{price} = unpack("V1", substr($msg, $i, 4));
		$item->{amount} = unpack("v1", substr($msg, $i + 4, 2));
		$item->{type} = unpack("C1", substr($msg, $i + 8, 1));
		$item->{nameID} = unpack("v1", substr($msg, $i + 9, 2));
		$item->{identified} = unpack("C1", substr($msg, $i + 11, 1));
		$item->{broken} = unpack("C1", substr($msg, $i + 12, 1));
		$item->{upgrade} = unpack("C1", substr($msg, $i + 13, 1));
		$item->{cards} = substr($msg, $i + 14, 8);
		$item->{name} = itemName($item);

		debug("Item added to Vender Store: $item->{name} - $item->{price} z\n", "vending", 2);

		Plugins::callHook('packet_vender_store', {
			venderID => $venderID,
			number => $number,
			name => $item->{name},
			amount => $item->{amount},
			price => $item->{price}
		});

		message(swrite(
			"@< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<<< @>>>>> @>>>>>>>>>z",
			[$number, $item->{name}, $itemTypes_lut{$item->{type}}, $item->{amount}, formatNumber($item->{price})]),
			"list");
	}
	message("-------------------------------------------------------------------------------\n", "list");

	Plugins::callHook('packet_vender_store2', {
		venderID => $venderID,
		itemList => \@venderItemList
	});	
}

sub vender_lost {
	my ($self, $args) = @_;

	my $ID = $args->{ID};
	binRemove(\@venderListsID, $ID);
	delete $venderLists{$ID};
}

sub vender_buy_fail {
	my ($self, $args) = @_;

	my $reason;
	if ($args->{fail} == 1) {
		error TF("Failed to buy %s of item #%s from vender (insufficient zeny).\n", $args->{amount}, $args->{index});
	} elsif ($args->{fail} == 2) {
		error TF("Failed to buy %s of item #%s from vender (overweight).\n", $args->{amount}, $args->{index});
	} else {
		error TF("Failed to buy %s of item #%s from vender (unknown code %s).\n", $args->{amount}, $args->{index}, $args->{fail});
	}
}

sub vending_start {
	my ($self, $args) = @_;
		
	my $msg = $args->{RAW_MSG};
	my $msg_size = unpack("v1",substr($msg, 2, 2));

	#started a shop.
	@articles = ();
	# FIXME: why do we need a seperate variable to track how many items are left in the store?
	$articles = 0;

	# FIXME: Read the packet the server sends us to determine
	# the shop title instead of using $shop{title}.
	message TF("%s\n" .
		"#  Name                                          Type        Amount       Price\n", 
		center(" $shop{title} ", 79, '-')), "list";
	for (my $i = 8; $i < $msg_size; $i += 22) {
		my $number = unpack("v1", substr($msg, $i + 4, 2));
		my $item = $articles[$number] = {};
		$item->{nameID} = unpack("v1", substr($msg, $i + 9, 2));
		$item->{quantity} = unpack("v1", substr($msg, $i + 6, 2));
		$item->{type} = unpack("C1", substr($msg, $i + 8, 1));
		$item->{identified} = unpack("C1", substr($msg, $i + 11, 1));
		$item->{broken} = unpack("C1", substr($msg, $i + 12, 1));
		$item->{upgrade} = unpack("C1", substr($msg, $i + 13, 1));
		$item->{cards} = substr($msg, $i + 14, 8);
		$item->{price} = unpack("V1", substr($msg, $i, 4));
		$item->{name} = itemName($item);
		$articles++;

		debug("Item added to Vender Store: $item->{name} - $item->{price} z\n", "vending", 2);

		message(swrite(
			"@< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<< @>>>>> @>>>>>>>>>z",
			[$articles, $item->{name}, $itemTypes_lut{$item->{type}}, $item->{quantity}, formatNumber($item->{price})]),
			"list");
	}
	message(('-'x79)."\n", "list");
	$shopEarned ||= 0;
}

sub warp_portal_list {
	my ($self, $args) = @_;
	
	# strip gat extension
	($args->{memo1}) = $args->{memo1} =~ /^(.*)\.gat/;
	($args->{memo2}) = $args->{memo2} =~ /^(.*)\.gat/;
	($args->{memo3}) = $args->{memo3} =~ /^(.*)\.gat/;
	($args->{memo4}) = $args->{memo4} =~ /^(.*)\.gat/;
	# Auto-detect saveMap
	if ($args->{type} == 26) {
		configModify('saveMap', $args->{memo2}) if $args->{memo2};
	} elsif ($args->{type} == 27) {
		configModify('saveMap', $args->{memo1}) if $args->{memo1};
	}

	$char->{warp}{type} = $args->{type};
	undef @{$char->{warp}{memo}};
	push @{$char->{warp}{memo}}, $args->{memo1} if $args->{memo1} ne "";
	push @{$char->{warp}{memo}}, $args->{memo2} if $args->{memo2} ne "";
	push @{$char->{warp}{memo}}, $args->{memo3} if $args->{memo3} ne "";
	push @{$char->{warp}{memo}}, $args->{memo4} if $args->{memo4} ne "";

	message T("----------------- Warp Portal --------------------\n" .
		"#  Place                           Map\n"), "list";
	for (my $i = 0; $i < @{$char->{warp}{memo}}; $i++) {
		message(swrite(
			"@< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<<<<<",
			[$i, $maps_lut{$char->{warp}{memo}[$i].'.rsw'},
			$char->{warp}{memo}[$i]]),
			"list");
	}
	message("--------------------------------------------------\n", "list");
}

1;

