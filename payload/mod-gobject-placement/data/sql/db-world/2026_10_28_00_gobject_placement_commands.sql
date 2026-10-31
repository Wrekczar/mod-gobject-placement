-- mod-gobject-placement: help text for `.help gobject pitch|roll|save`. Touches only these three rows.
DELETE FROM `command` WHERE `name` IN ('gobject pitch', 'gobject roll', 'gobject save');
INSERT INTO `command` (`name`, `security`, `help`) VALUES
('gobject pitch', 3, 'Syntax: .gobject pitch #goguid #degrees\r\n\r\nTilts gameobject #goguid about its own Y axis (nose down for positive #degrees), added to its current rotation. Saves the four rotation columns to the database and respawns the object so the change shows at once.'),
('gobject roll', 3, 'Syntax: .gobject roll #goguid #degrees\r\n\r\nTilts gameobject #goguid about its own X axis (forward axis), added to its current rotation. Saves the four rotation columns to the database and respawns the object so the change shows at once.'),
('gobject save', 3, 'Syntax: .gobject save #goguid\r\n\r\nRecords the current placement of gameobject #goguid (entry, map, position, orientation, rotation, time) as its verified placement in the characters database table gobject_placement_verified. Does not move the object. Every save is also kept in gobject_placement_history.');
