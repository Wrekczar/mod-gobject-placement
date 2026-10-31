/*
 * mod-gobject-placement: .gobject pitch / roll / save
 * Released under GNU GPL v2 or later, like the AzerothCore code it extends.
 */

#ifndef GOBJECT_PLACEMENT_MATH_H
#define GOBJECT_PLACEMENT_MATH_H

#include "G3D/Matrix3.h"
#include "G3D/Quat.h"
#include "G3D/Vector3.h"
#include "G3D/g3dmath.h"
#include <cmath>

namespace GObjectPlacement
{
    constexpr float MaxStepDegrees = 360.0f;

    struct EulerDegrees
    {
        float yaw;
        float pitch;
        float roll;
    };

    // Unit length with w >= 0. q and -q are the same rotation; one sign keeps stored values comparable.
    inline G3D::Quat Canonical(G3D::Quat rotation)
    {
        rotation.unitize();
        if (rotation.w < 0.0f)
            rotation = rotation * -1.0f;
        return rotation;
    }

    // Rotation the server actually uses for a spawn: an all-zero quaternion falls back to the orientation,
    // as in GameObject::SetWorldRotation.
    inline G3D::Quat Effective(G3D::Quat const& rotation, float orientation)
    {
        if (G3D::fuzzyEq(rotation.magnitude(), 0.0f))
            return Canonical(G3D::Quat::fromAxisAngleRotation(G3D::Vector3::unitZ(), orientation));
        return Canonical(rotation);
    }

    // Post-multiplying applies the step about the object's own axis, so earlier yaw/pitch/roll stay intact.
    inline G3D::Quat RotateAboutLocalAxis(G3D::Quat const& rotation, G3D::Vector3 const& localAxis, float degrees)
    {
        float const radians = degrees * float(G3D::pi()) / 180.0f;
        return Canonical(rotation * G3D::Quat::fromAxisAngleRotation(localAxis, radians));
    }

    inline G3D::Quat Pitch(G3D::Quat const& rotation, float degrees)
    {
        return RotateAboutLocalAxis(rotation, G3D::Vector3::unitY(), degrees);
    }

    inline G3D::Quat Roll(G3D::Quat const& rotation, float degrees)
    {
        return RotateAboutLocalAxis(rotation, G3D::Vector3::unitX(), degrees);
    }

    // Same Z-Y-X convention as GameObject::SetWorldRotationAngles (and so `.gobject turn z y x`).
    inline EulerDegrees ToEulerDegrees(G3D::Quat const& rotation)
    {
        float yaw = 0.0f, pitch = 0.0f, roll = 0.0f;
        rotation.toUnit().toRotationMatrix().toEulerAnglesZYX(yaw, pitch, roll);
        float const toDegrees = 180.0f / float(G3D::pi());
        return { yaw * toDegrees, pitch * toDegrees, roll * toDegrees };
    }

    inline bool IsValidStep(float degrees)
    {
        return std::isfinite(degrees) && degrees != 0.0f && std::fabs(degrees) <= MaxStepDegrees;
    }
}

#endif
