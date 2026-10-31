// Standalone checks for GObjectPlacementMath.h against the core's own G3D library.
// Build: tests/run_math_test.cmd (needs a built g3dlib.lib; see README "Testing").

#include "GObjectPlacementMath.h"
#include <cstdio>
#include <cstdlib>
#include <limits>

using namespace GObjectPlacement;

static int failures = 0;
static int checks = 0;

static void Check(bool ok, char const* what)
{
    ++checks;
    if (!ok)
    {
        ++failures;
        std::printf("FAIL: %s\n", what);
    }
}

static bool Near(float a, float b, float tol = 1e-3f) { return std::fabs(a - b) <= tol; }

static bool SameRotation(G3D::Quat a, G3D::Quat b, float tol = 1e-5f)
{
    a = Canonical(a);
    b = Canonical(b);
    return Near(a.x, b.x, tol) && Near(a.y, b.y, tol) && Near(a.z, b.z, tol) && Near(a.w, b.w, tol);
}

static bool SameVector(G3D::Vector3 const& a, G3D::Vector3 const& b, float tol = 1e-5f)
{
    return Near(a.x, b.x, tol) && Near(a.y, b.y, tol) && Near(a.z, b.z, tol);
}

static G3D::Quat FromTurn(float yawDeg, float pitchDeg, float rollDeg)
{
    float const r = float(G3D::pi()) / 180.0f;
    return Canonical(G3D::Quat(G3D::Matrix3::fromEulerAnglesZYX(yawDeg * r, pitchDeg * r, rollDeg * r)));
}

static G3D::Vector3 Axis(G3D::Quat const& q, G3D::Vector3 const& local)
{
    return q.toRotationMatrix() * local;
}

static bool IsUnit(G3D::Quat const& q) { return Near(q.magnitude(), 1.0f, 1e-6f); }

int main()
{
    G3D::Quat const yaw30 = FromTurn(30.0f, 0.0f, 0.0f);

    {
        G3D::Quat q = Pitch(yaw30, 5.0f);
        EulerDegrees e = ToEulerDegrees(q);
        Check(Near(e.yaw, 30.0f) && Near(e.pitch, 5.0f) && Near(e.roll, 0.0f), "positive pitch adds 5 deg, keeps yaw");
        Check(IsUnit(q), "positive pitch result is unit length");
        Check(Axis(q, G3D::Vector3::unitX()).z < 0.0f, "positive pitch tilts the forward axis down");
    }
    {
        G3D::Quat q = Pitch(yaw30, -5.0f);
        EulerDegrees e = ToEulerDegrees(q);
        Check(Near(e.yaw, 30.0f) && Near(e.pitch, -5.0f) && Near(e.roll, 0.0f), "negative pitch subtracts 5 deg");
    }
    {
        G3D::Quat q = Roll(yaw30, 10.0f);
        EulerDegrees e = ToEulerDegrees(q);
        Check(Near(e.yaw, 30.0f) && Near(e.pitch, 0.0f) && Near(e.roll, 10.0f), "positive roll adds 10 deg, keeps yaw");
    }
    {
        G3D::Quat q = Roll(yaw30, -10.0f);
        EulerDegrees e = ToEulerDegrees(q);
        Check(Near(e.yaw, 30.0f) && Near(e.pitch, 0.0f) && Near(e.roll, -10.0f), "negative roll subtracts 10 deg");
    }
    {
        Check(SameRotation(Pitch(Pitch(yaw30, 5.0f), -5.0f), yaw30), "pitch +5 then -5 restores the rotation");
        Check(SameRotation(Roll(Roll(yaw30, 10.0f), -10.0f), yaw30), "roll +10 then -10 restores the rotation");
    }
    {
        G3D::Quat q = yaw30;
        for (int i = 0; i < 5; ++i)
            q = Pitch(q, 1.0f);
        Check(SameRotation(q, Pitch(yaw30, 5.0f), 1e-5f), "five 1-deg pitches equal one 5-deg pitch");

        G3D::Quat spin = yaw30;
        for (int i = 0; i < 72; ++i)
            spin = Roll(spin, 5.0f);
        Check(SameRotation(spin, yaw30, 1e-4f), "72 x 5-deg rolls return to the start");

        G3D::Quat drift = yaw30;
        for (int i = 0; i < 10000; ++i)
            drift = (i % 2) ? Pitch(drift, 0.7f) : Roll(drift, -1.3f);
        Check(IsUnit(drift), "10000 mixed steps stay unit length");
    }
    {
        G3D::Quat q = Roll(Pitch(yaw30, 10.0f), 20.0f);
        Check(SameRotation(q, FromTurn(30.0f, 10.0f, 20.0f)),
            "yaw then pitch then roll equals `.gobject turn 30 10 20` (Z-Y-X)");
        EulerDegrees e = ToEulerDegrees(q);
        Check(Near(e.yaw, 30.0f) && Near(e.pitch, 10.0f) && Near(e.roll, 20.0f), "combined angles read back");
    }
    {
        G3D::Quat start = FromTurn(30.0f, 10.0f, 0.0f);
        G3D::Quat rolled = Roll(start, 25.0f);
        Check(SameVector(Axis(start, G3D::Vector3::unitX()), Axis(rolled, G3D::Vector3::unitX())),
            "roll keeps the forward axis, so it never changes yaw or pitch of the heading");

        G3D::Quat tilted = FromTurn(30.0f, 0.0f, 15.0f);
        G3D::Quat pitched = Pitch(tilted, 12.0f);
        Check(SameVector(Axis(tilted, G3D::Vector3::unitY()), Axis(pitched, G3D::Vector3::unitY())),
            "pitch keeps the side axis, so an existing roll is not reset");
        Check(!SameRotation(pitched, FromTurn(30.0f, 12.0f, 0.0f)), "pitch on a rolled object does not drop the roll");
    }
    {
        G3D::Quat raw(0.0f, 0.0f, 0.6f, 2.4f);
        Check(IsUnit(Pitch(raw, 3.0f)), "a non-unit stored rotation is normalised");
        Check(Pitch(raw, 3.0f).w >= 0.0f, "result has w >= 0");
        G3D::Quat negative = yaw30 * -1.0f;
        Check(SameRotation(Pitch(negative, 5.0f), Pitch(yaw30, 5.0f)), "q and -q give the same result");
        Check(Canonical(negative).w >= 0.0f, "canonical form flips negative w");
    }
    {
        float const o = 1.2f;
        G3D::Quat zero(0.0f, 0.0f, 0.0f, 0.0f);
        G3D::Quat e = Effective(zero, o);
        Check(SameRotation(e, G3D::Quat::fromAxisAngleRotation(G3D::Vector3::unitZ(), o)),
            "an all-zero stored rotation falls back to the orientation, as the server does");
        Check(SameRotation(Effective(yaw30, 2.0f), yaw30), "a real rotation ignores the orientation column");
    }
    {
        float const nan = std::numeric_limits<float>::quiet_NaN();
        float const inf = std::numeric_limits<float>::infinity();
        Check(IsValidStep(5.0f) && IsValidStep(-5.0f) && IsValidStep(360.0f) && IsValidStep(-0.25f), "valid steps");
        Check(!IsValidStep(0.0f) && !IsValidStep(nan) && !IsValidStep(inf) && !IsValidStep(-inf)
            && !IsValidStep(360.5f) && !IsValidStep(-1000.0f), "invalid steps rejected");
    }

    std::printf("%d checks, %d failed\n", checks, failures);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
