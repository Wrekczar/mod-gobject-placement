-- mod-gobject-placement: saved gameobject placements.
-- Kept in the characters database so a rebuilt or re-imported world database cannot erase them.
-- Spawn guids are not trusted alone: entry, map and script_name are stored as identity checks.

-- Latest verified placement per spawn, written by `.gobject save`.
CREATE TABLE IF NOT EXISTS `gobject_placement_verified` (
  `guid` INT UNSIGNED NOT NULL COMMENT 'gameobject.guid at save time',
  `entry` INT UNSIGNED NOT NULL COMMENT 'gameobject.id',
  `map` SMALLINT UNSIGNED NOT NULL,
  `script_name` VARCHAR(64) NOT NULL DEFAULT '' COMMENT 'gameobject.ScriptName column (not the template)',
  `position_x` FLOAT NOT NULL,
  `position_y` FLOAT NOT NULL,
  `position_z` FLOAT NOT NULL,
  `orientation` FLOAT NOT NULL,
  `rotation0` FLOAT NOT NULL,
  `rotation1` FLOAT NOT NULL,
  `rotation2` FLOAT NOT NULL,
  `rotation3` FLOAT NOT NULL,
  `saved_by_account` INT UNSIGNED NOT NULL DEFAULT 0,
  `saved_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revision` INT UNSIGNED NOT NULL DEFAULT 1 COMMENT 'number of saves of this guid',
  PRIMARY KEY (`guid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Every save ever made (append only): the recovery path when a resave was a mistake.
CREATE TABLE IF NOT EXISTS `gobject_placement_history` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `guid` INT UNSIGNED NOT NULL,
  `entry` INT UNSIGNED NOT NULL,
  `map` SMALLINT UNSIGNED NOT NULL,
  `script_name` VARCHAR(64) NOT NULL DEFAULT '',
  `position_x` FLOAT NOT NULL,
  `position_y` FLOAT NOT NULL,
  `position_z` FLOAT NOT NULL,
  `orientation` FLOAT NOT NULL,
  `rotation0` FLOAT NOT NULL,
  `rotation1` FLOAT NOT NULL,
  `rotation2` FLOAT NOT NULL,
  `rotation3` FLOAT NOT NULL,
  `saved_by_account` INT UNSIGNED NOT NULL DEFAULT 0,
  `saved_at` TIMESTAMP NOT NULL,
  `revision` INT UNSIGNED NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_guid` (`guid`, `revision`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Placement before this module first touched a spawn (first `.gobject pitch`, `roll` or `save`; never
-- overwritten). Used as the "expected" (source) state when exporting corrections.
CREATE TABLE IF NOT EXISTS `gobject_placement_baseline` (
  `guid` INT UNSIGNED NOT NULL,
  `entry` INT UNSIGNED NOT NULL,
  `map` SMALLINT UNSIGNED NOT NULL,
  `script_name` VARCHAR(64) NOT NULL DEFAULT '',
  `position_x` FLOAT NOT NULL,
  `position_y` FLOAT NOT NULL,
  `position_z` FLOAT NOT NULL,
  `orientation` FLOAT NOT NULL,
  `rotation0` FLOAT NOT NULL,
  `rotation1` FLOAT NOT NULL,
  `rotation2` FLOAT NOT NULL,
  `rotation3` FLOAT NOT NULL,
  `captured_by_command` VARCHAR(16) NOT NULL COMMENT 'pitch, roll or save',
  `captured_by_account` INT UNSIGNED NOT NULL DEFAULT 0,
  `captured_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`guid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
