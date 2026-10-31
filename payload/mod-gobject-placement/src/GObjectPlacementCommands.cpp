/*
 * mod-gobject-placement: .gobject pitch / roll / save
 * Released under GNU GPL v2 or later, like the AzerothCore code it extends.
 */

#include "Chat.h"
#include "CommandScript.h"
#include "DatabaseEnv.h"
#include "GObjectPlacementMath.h"
#include "GameObject.h"
#include "Language.h"
#include "Map.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "WorldSession.h"

using namespace Acore::ChatCommands;

namespace
{
    using GameObjectSpawnId = Variant<Hyperlink<gameobject>, ObjectGuid::LowType>;

    struct Placement
    {
        uint32 spawnId;
        uint32 entry;
        uint16 map;
        std::string scriptName;
        float x;
        float y;
        float z;
        float orientation;
        G3D::Quat rotation;
    };

    std::string Escaped(std::string text)
    {
        CharacterDatabase.EscapeString(text);
        return text;
    }

    Optional<std::string> ReadRowScriptName(uint32 spawnId)
    {
        QueryResult result = WorldDatabase.Query("SELECT ScriptName FROM gameobject WHERE guid = {}", spawnId);
        if (!result)
            return std::nullopt;
        return result->Fetch()[0].Get<std::string>();
    }

    Optional<Placement> CurrentPlacement(uint32 spawnId)
    {
        GameObjectData const* data = sObjectMgr->GetGameObjectData(spawnId);
        if (!data)
            return std::nullopt;

        Optional<std::string> scriptName = ReadRowScriptName(spawnId);
        if (!scriptName)
            return std::nullopt;

        return Placement{ spawnId, data->id, data->mapid, *scriptName, data->posX, data->posY, data->posZ,
            data->orientation, data->rotation };
    }

    // The rotation the client is shown (an all-zero stored rotation falls back to the orientation).
    Placement WithEffectiveRotation(Placement p)
    {
        p.rotation = GObjectPlacement::Effective(p.rotation, p.orientation);
        return p;
    }

    std::string PlacementColumns()
    {
        return "guid, entry, map, script_name, position_x, position_y, position_z, orientation, "
            "rotation0, rotation1, rotation2, rotation3";
    }

    std::string PlacementValues(Placement const& p)
    {
        return Acore::StringFormat("{}, {}, {}, '{}', {}, {}, {}, {}, {}, {}, {}, {}", p.spawnId, p.entry, p.map,
            Escaped(p.scriptName), p.x, p.y, p.z, p.orientation,
            p.rotation.x, p.rotation.y, p.rotation.z, p.rotation.w);
    }

    void AppendBaselineOnce(CharacterDatabaseTransaction& trans, Placement const& p, std::string_view command,
        uint32 accountId)
    {
        trans->Append("INSERT IGNORE INTO gobject_placement_baseline ({}, captured_by_command, captured_by_account) "
            "VALUES ({}, '{}', {})", PlacementColumns(), PlacementValues(p), command, accountId);
    }

    void RecordBaselineOnce(Placement const& p, std::string_view command, uint32 accountId)
    {
        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
        AppendBaselineOnce(trans, p, command, accountId);
        CharacterDatabase.CommitTransaction(trans);
    }

    char const* UnsupportedReason(GameObject const* object)
    {
        switch (object->GetGoType())
        {
            case GAMEOBJECT_TYPE_TRANSPORT:
            case GAMEOBJECT_TYPE_MO_TRANSPORT:
                return "transports cannot be rotated with this command";
            case GAMEOBJECT_TYPE_DESTRUCTIBLE_BUILDING:
                return "destructible buildings would lose their damage state when respawned";
            default:
                break;
        }
        if (object->GetTransport())
            return "objects riding a transport use a transport-relative rotation";
        return nullptr;
    }

    bool Rotate(ChatHandler* handler, GameObjectSpawnId spawnIdArg, float degrees, bool pitch)
    {
        char const* commandName = pitch ? "pitch" : "roll";
        uint32 const spawnId = uint32(spawnIdArg);

        if (!GObjectPlacement::IsValidStep(degrees))
        {
            handler->SendErrorMessage("Degrees must be a non-zero number between -{0} and {0}.",
                GObjectPlacement::MaxStepDegrees);
            return false;
        }

        GameObject* object = handler->GetObjectFromPlayerMapByDbGuid(spawnId);
        if (!object)
        {
            handler->SendErrorMessage(LANG_COMMAND_OBJNOTFOUND, spawnId);
            return false;
        }

        if (char const* reason = UnsupportedReason(object))
        {
            handler->SendErrorMessage("Gameobject spawn {} is not supported: {}.", spawnId, reason);
            return false;
        }

        Optional<Placement> before = CurrentPlacement(spawnId);
        if (!before)
        {
            handler->SendErrorMessage("Gameobject spawn {} has no row in the world database `gameobject` table.",
                spawnId);
            return false;
        }

        uint32 const accountId = handler->GetSession()->GetAccountId();
        RecordBaselineOnce(*before, commandName, accountId);

        G3D::Quat const current = GObjectPlacement::Effective(object->GetWorldRotation(), object->GetOrientation());
        G3D::Quat const rotated = pitch ? GObjectPlacement::Pitch(current, degrees)
                                        : GObjectPlacement::Roll(current, degrees);

        // Only the four rotation columns change; `.gobject turn` rewrites the whole row and drops
        // ScriptName, Comment, zoneId and areaId.
        sObjectMgr->NewGOData(spawnId).rotation = rotated;
        WorldDatabase.Execute("UPDATE gameobject SET rotation0 = {}, rotation1 = {}, rotation2 = {}, rotation3 = {} "
            "WHERE guid = {}", rotated.x, rotated.y, rotated.z, rotated.w, spawnId);

        // As in `.gobject turn`: the 3.3.5a client ignores a changed rotation for a GUID it has cached,
        // so the object is despawned and recreated from the updated spawn data under a new GUID.
        std::string const name = object->GetGOInfo()->name;
        Map* map = object->GetMap();
        object->Delete();

        GameObject* reloaded = new GameObject();
        if (!reloaded->LoadGameObjectFromDB(spawnId, map, true))
        {
            delete reloaded;
            handler->SendErrorMessage("Rotation of spawn {} was saved, but the object could not be respawned; "
                "it will appear correctly after a restart.", spawnId);
            return false;
        }

        GObjectPlacement::EulerDegrees const euler = GObjectPlacement::ToEulerDegrees(rotated);
        handler->PSendSysMessage("{} {} (spawn {}) by {:+.2f} deg. Rotation x={:.6f} y={:.6f} z={:.6f} w={:.6f} "
            "(yaw {:.2f}, pitch {:.2f}, roll {:.2f}).", pitch ? "Pitched" : "Rolled", name, spawnId, degrees,
            rotated.x, rotated.y, rotated.z, rotated.w, euler.yaw, euler.pitch, euler.roll);
        return true;
    }
}

class gobject_placement_commandscript : public CommandScript
{
public:
    gobject_placement_commandscript() : CommandScript("gobject_placement_commandscript") { }

    ChatCommandTable GetCommands() const override
    {
        // Merged into the core's `.gobject` table. Level 3 matches the effective level of `.gobject turn`
        // (the core `command` table sets it to 3).
        static ChatCommandTable gobjectCommandTable =
        {
            { "pitch", HandlePitchCommand, SEC_ADMINISTRATOR, Console::No },
            { "roll",  HandleRollCommand,  SEC_ADMINISTRATOR, Console::No },
            { "save",  HandleSaveCommand,  SEC_ADMINISTRATOR, Console::No }
        };
        static ChatCommandTable commandTable =
        {
            { "gobject", gobjectCommandTable }
        };
        return commandTable;
    }

    static bool HandlePitchCommand(ChatHandler* handler, GameObjectSpawnId spawnId, float degrees)
    {
        return Rotate(handler, spawnId, degrees, true);
    }

    static bool HandleRollCommand(ChatHandler* handler, GameObjectSpawnId spawnId, float degrees)
    {
        return Rotate(handler, spawnId, degrees, false);
    }

    static bool HandleSaveCommand(ChatHandler* handler, GameObjectSpawnId spawnIdArg)
    {
        uint32 const spawnId = uint32(spawnIdArg);
        Optional<Placement> placement = CurrentPlacement(spawnId);
        if (!placement)
        {
            handler->SendErrorMessage("Gameobject spawn {} was not found (no loaded spawn data or no row in the "
                "world database `gameobject` table).", spawnId);
            return false;
        }

        uint32 const accountId = handler->GetSession()->GetAccountId();
        Placement const p = WithEffectiveRotation(*placement);

        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
        AppendBaselineOnce(trans, *placement, "save", accountId);
        trans->Append("INSERT INTO gobject_placement_verified ({}, saved_by_account) VALUES ({}, {}) "
            "ON DUPLICATE KEY UPDATE entry = VALUES(entry), map = VALUES(map), script_name = VALUES(script_name), "
            "position_x = VALUES(position_x), position_y = VALUES(position_y), position_z = VALUES(position_z), "
            "orientation = VALUES(orientation), rotation0 = VALUES(rotation0), rotation1 = VALUES(rotation1), "
            "rotation2 = VALUES(rotation2), rotation3 = VALUES(rotation3), "
            "saved_by_account = VALUES(saved_by_account), saved_at = CURRENT_TIMESTAMP, revision = revision + 1",
            PlacementColumns(), PlacementValues(p), accountId);
        trans->Append("INSERT INTO gobject_placement_history ({0}, saved_by_account, saved_at, revision) "
            "SELECT {0}, saved_by_account, saved_at, revision FROM gobject_placement_verified WHERE guid = {1}",
            PlacementColumns(), spawnId);
        CharacterDatabase.CommitTransaction(trans);

        GameObjectTemplate const* goInfo = sObjectMgr->GetGameObjectTemplate(p.entry);
        GObjectPlacement::EulerDegrees const euler = GObjectPlacement::ToEulerDegrees(p.rotation);
        handler->PSendSysMessage("Saved verified placement of {} (spawn {}, entry {}): map {} X {:.4f} Y {:.4f} "
            "Z {:.4f} O {:.4f}, rotation x={:.6f} y={:.6f} z={:.6f} w={:.6f} (yaw {:.2f}, pitch {:.2f}, roll {:.2f}). "
            "Earlier saves stay in gobject_placement_history.", goInfo ? goInfo->name : "?", spawnId, p.entry, p.map,
            p.x, p.y, p.z, p.orientation, p.rotation.x, p.rotation.y, p.rotation.z, p.rotation.w,
            euler.yaw, euler.pitch, euler.roll);
        return true;
    }
};

void AddGObjectPlacementScripts()
{
    new gobject_placement_commandscript();
}
