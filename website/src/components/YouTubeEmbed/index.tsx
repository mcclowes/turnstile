import React from 'react';
import styles from './styles.module.css';

type Props = {
  id: string;
  title: string;
};

export default function YouTubeEmbed({id, title}: Props): React.JSX.Element {
  return (
    <div className={styles.frame}>
      <iframe
        src={`https://www.youtube-nocookie.com/embed/${id}`}
        title={title}
        loading="lazy"
        allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
        referrerPolicy="strict-origin-when-cross-origin"
        allowFullScreen
      />
    </div>
  );
}
