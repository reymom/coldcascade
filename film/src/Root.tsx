import { Composition } from "remotion";
import { Mechanism, DURATION, FPS } from "./Mechanism";

export const Root: React.FC = () => (
  <>
    <Composition id="Mechanism" component={Mechanism} durationInFrames={DURATION} fps={FPS} width={1920} height={1080} />
    {/* v4, kept for the archive */}
  </>
);
