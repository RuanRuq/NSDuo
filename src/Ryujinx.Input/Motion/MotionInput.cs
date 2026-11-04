using Ryujinx.Input.Motion;
using System;
using System.Numerics;

namespace Ryujinx.Input
{
    public class MotionInput
    {
        public ulong TimeStamp { get; set; }
        public Vector3 Accelerometer { get; set; }
        public Vector3 Gyroscrope { get; set; }
        public Vector3 Rotation { get; set; }

        private readonly MotionSensorFilter _filter;

        public MotionInput()
        {
            TimeStamp = 0;
            Accelerometer = new Vector3();
            Gyroscrope = new Vector3();
            Rotation = new Vector3();

            // TODO: RE the correct filter.
            _filter = new MotionSensorFilter(0f);
        }

        public void Update(Vector3 accel, Vector3 gyro, ulong timestamp, int sensitivity, float deadzone)
        {
            // Do not integrate the whole time spent paused/backgrounded into the first
            // resumed sample, or a small movement becomes a large aim/attitude jump.
            bool continuous = TimeStamp != 0 && timestamp > TimeStamp && timestamp - TimeStamp <= 100000;
            Accelerometer = -accel;
            Gyroscrope = gyro.Length() < deadzone ? Vector3.Zero : gyro * (sensitivity / 100f);

            if (continuous)
            {
                float deltaTime = (timestamp - TimeStamp) / 1000000f;

                Vector3 deltaGyro = Gyroscrope * deltaTime;

                Rotation += deltaGyro;

                _filter.SamplePeriod = deltaTime;
                _filter.Update(accel, DegreeToRad(Gyroscrope));
            }

            TimeStamp = timestamp;
        }

        public Matrix4x4 GetOrientation()
        {
            return Matrix4x4.CreateFromQuaternion(_filter.Quaternion);
        }

        private static Vector3 DegreeToRad(Vector3 degree)
        {
            return degree * (MathF.PI / 180);
        }
    }
}
