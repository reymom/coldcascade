import { Composition } from "remotion";
import { Film } from "./Film";
import { Mechanism, DURATION, FPS } from "./Mechanism";

export const Root: React.FC = () => (
  <>
    <Composition id="Mechanism" component={Mechanism} durationInFrames={DURATION} fps={FPS} width={1920} height={1080} />
    {/* v4, kept for the archive */}
    <Composition id="Film" component={Film} durationInFrames={2400} fps={60} width={1920} height={1080} />
  </>
);
